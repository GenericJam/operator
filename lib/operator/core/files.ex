defmodule Operator.Core.Files do
  @moduledoc """
  Where the agent's file tools (`file_*`) and Dyn code (front screens, Dyn
  tools) may read and write: a few roots, and nothing outside them.

    * `workspace`: `<data dir>/workspace`, Operator's own, always there.
    * `shared` (Android): the phone's shared storage, `/storage/emulated/0`
      (Download, DCIM, Documents, Pictures, ...). It needs "All files
      access" (MANAGE_EXTERNAL_STORAGE), which the user switches on in
      Settings the first time it's needed (a screen asks with
      `Mob.Permissions.request(socket, :all_files)`).

  The rest of the data dir (sessions, Dyn generations, settings) is not a
  root: Dyn code can't read the store it's kept in. A relative path is
  taken inside the workspace; `..` and symlinks are resolved before the
  check, so neither leads out of a root.

  Dyn code may not call `File` itself; `read/1`, `write/2`, `ls/1`,
  `stat/1`, `mkdir_p/1`, `rm/1` and `expand/1` here are its file access,
  the same calls checked against the roots. The file tools' side
  (`roots/1`, `workspace/1`, `resolve/3`, ...) takes a caller's ctx and
  is off limits to Dyn code (`Operator.Core.Dyn.Check`).

  What the phone's capabilities hand a screen (a `Mob.Files.pick/2` pick, a
  `MobCamera` photo, a `MobPhotos` pick, a recording) is a file in the app's
  temporary files (Android's cache dir, iOS's tmp), which is no root.
  `Operator.ShellScreen` marks the exact paths delivered by native code for
  the current front host; `keep/2` consumes one such process-local grant and
  copies that file into the workspace's `inbox/`, where `read/1` reaches it.
  Merely guessing another cache filename is not authorization.

  `ctx[:file_roots]` replaces the roots (tests); otherwise the workspace is
  under `ctx[:data_dir]` or `Operator.Paths.data_dir/0`. The app env
  `:operator, :app_temp` (a dir) replaces the temporary files' dir (tests).
  """

  alias Operator.Core.Attachments
  alias Operator.Core.Term
  alias Operator.Core.Tools.FileTool

  @type root :: %{
          name: String.t(),
          path: Path.t(),
          access: :read_write | :read,
          about: String.t()
        }

  @shared "/storage/emulated/0"
  @capability_grants {__MODULE__, :capability_grants}

  @doc false
  @spec roots(map()) :: [root()]
  def roots(ctx \\ %{}) do
    Map.get_lazy(ctx, :file_roots, fn -> default_roots(ctx) end)
  end

  defp default_roots(ctx) do
    data_dir = Map.get_lazy(ctx, :data_dir, &Operator.Paths.data_dir/0)

    [
      %{
        name: "workspace",
        path: Path.join(data_dir, "workspace"),
        access: :read_write,
        about: workspace_about()
      }
    ] ++ shared_root()
  end

  defp workspace_about do
    if Term.platform() == :android,
      do: "Operator's own files (private to the app; copy to shared storage to hand one out)",
      else: "Operator's own files (private to the app)"
  end

  defp shared_root do
    if Term.platform() == :android do
      [
        %{
          name: "shared",
          path: @shared,
          access: :read_write,
          about:
            "the phone's shared storage: Download, DCIM (camera photos), Documents, Pictures, " <>
              "... (needs All files access, asked the first time)"
        }
      ]
    else
      []
    end
  end

  @doc false
  # The workspace dir (created).
  @spec workspace(map()) :: Path.t()
  def workspace(ctx \\ %{}) do
    %{path: path} = Enum.find(roots(ctx), &(&1.name == "workspace"))
    File.mkdir_p!(path)
    path
  end

  @doc false
  # The absolute path for `path` and the root it's in, if `mode` (`:read`
  # or `:write`) is allowed there.
  @spec resolve(String.t(), :read | :write, map()) ::
          {:ok, Path.t(), root()} | {:error, String.t()}
  def resolve(path, mode, ctx \\ %{})

  def resolve(path, mode, ctx) when is_binary(path) and path != "" do
    roots = roots(ctx)
    workspace = Enum.find(roots, &(&1.name == "workspace"))
    _ = File.mkdir_p(workspace.path)
    abs = if Path.type(path) == :absolute, do: path, else: Path.join(workspace.path, path)
    real = real_path(Path.expand(abs))

    case Enum.find(roots, &inside?(real, real_path(&1.path))) do
      nil ->
        {:error,
         "#{path} is outside the places files may be used (#{Enum.map_join(roots, ", ", &"#{&1.name}: #{&1.path}")})."}

      %{access: :read} = root when mode == :write ->
        {:error, "#{root.name} (#{root.path}) is read-only."}

      root ->
        {:ok, real, root}
    end
  end

  def resolve(_path, _mode, _ctx), do: {:error, "No path given."}

  @doc false
  # Whether using `root` needs the user's All files access (Android's shared storage).
  @spec needs_access?(root()) :: boolean()
  def needs_access?(%{name: "shared"}), do: true
  def needs_access?(_root), do: false

  # ── For Dyn code: File's calls, inside the roots. A refused path is
  # {:error, text}; the file system's own errors stay posix atoms. ──

  @doc "Reads a file (`File.read/1`)."
  @spec read(String.t()) :: {:ok, binary()} | {:error, atom() | String.t()}
  def read(path), do: with_path(path, :read, &File.read/1)

  @doc "Writes a file, creating its directory (`File.write/3`; `[:append]` to append)."
  @spec write(String.t(), iodata(), [:append]) :: :ok | {:error, atom() | String.t()}
  def write(path, data, modes \\ []) do
    with_path(path, :write, fn abs ->
      with :ok <- File.mkdir_p(Path.dirname(abs)), do: File.write(abs, data, modes)
    end)
  end

  @doc "A directory's entry names (`File.ls/1`); the workspace without a path."
  @spec ls(String.t()) :: {:ok, [String.t()]} | {:error, atom() | String.t()}
  def ls(path \\ "."), do: with_path(path, :read, &File.ls/1)

  @doc "`File.stat/1`."
  @spec stat(String.t()) :: {:ok, File.Stat.t()} | {:error, atom() | String.t()}
  def stat(path), do: with_path(path, :read, &File.stat/1)

  @doc "`File.mkdir_p/1`."
  @spec mkdir_p(String.t()) :: :ok | {:error, atom() | String.t()}
  def mkdir_p(path), do: with_path(path, :write, &File.mkdir_p/1)

  @doc "Deletes a file or an empty directory (`File.rm/1`, `File.rmdir/1`); never a root."
  @spec rm(String.t()) :: :ok | {:error, atom() | String.t()}
  def rm(path) do
    with {:ok, abs, root} <- resolve(path, :write) do
      cond do
        abs == real_path(root.path) -> {:error, "#{abs} is the #{root.name} root itself."}
        File.dir?(abs) -> File.rmdir(abs)
        true -> File.rm(abs)
      end
    end
  end

  @doc "The absolute path `path` stands for, if it's inside a root."
  @spec expand(String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def expand(path) do
    with {:ok, abs, _root} <- resolve(path, :read), do: {:ok, abs}
  end

  @doc """
  Copies one native capability result into the workspace's `inbox/`, as
  `name` if given (else its own name; `name-2`, … if taken), and returns its
  path there. The exact path must first have arrived from native code through
  `grant_capability/1`; each grant is consumed by one call.
  """
  @spec keep(String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  def keep(path, name \\ nil)

  def keep(path, name) when is_binary(path) do
    with {:ok, src} <- app_temp_file(path),
         :ok <- consume_grant(src) do
      inbox = Path.join(workspace(), "inbox")
      dest = Attachments.unique(inbox, Attachments.named(plain_name(name), src))

      with :ok <- File.mkdir_p(inbox),
           :ok <- File.cp(src, dest) do
        {:ok, dest}
      else
        {:error, reason} -> {:error, "Couldn't keep it: " <> FileTool.posix(reason, path)}
      end
    end
  end

  def keep(other, _name), do: {:error, "Not a path: #{inspect(other, limit: 5)}."}

  @doc false
  @spec grant_capability(term()) :: :ok
  def grant_capability(result) do
    granted =
      result
      |> capability_paths()
      |> Enum.reduce(grants(), fn path, acc ->
        case app_temp_file(path) do
          {:ok, real} -> MapSet.put(acc, real)
          {:error, _reason} -> acc
        end
      end)

    Process.put(@capability_grants, granted)
    :ok
  end

  @doc "Reads and removes a temporary thumbnail of an authorized workspace/shared image."
  @spec thumbnail(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def thumbnail(path, opts \\ []) do
    with {:ok, source, _root} <- resolve(path, :read),
         {:ok, %{path: thumb}} <- MobPhotos.thumbnail(source, opts) do
      try do
        File.read(thumb)
      after
        _ = File.rm(thumb)
      end
    end
  end

  defp consume_grant(path) do
    granted = grants()

    if MapSet.member?(granted, path) do
      Process.put(@capability_grants, MapSet.delete(granted, path))
      :ok
    else
      {:error, "#{path} wasn't handed to this screen by a phone capability."}
    end
  end

  defp grants, do: Process.get(@capability_grants, MapSet.new())

  defp capability_paths({:files, :picked, items}) when is_list(items),
    do: paths(items)

  defp capability_paths({:photos, :picked, items}) when is_list(items),
    do: paths(items)

  defp capability_paths({:camera, :photo, item}) when is_map(item), do: paths([item])
  defp capability_paths({:audio, :recorded, item}) when is_map(item), do: paths([item])
  defp capability_paths(_result), do: []

  defp paths(items),
    do: for(%{path: path} <- items, is_binary(path), do: path)

  defp app_temp_file(path) do
    case app_temp() do
      nil ->
        {:error, "There are no temporary files here (not on a phone)."}

      dir ->
        real = real_path(Path.expand(path))
        dir = real_path(Path.expand(dir))

        if ".." not in Path.split(path) and String.starts_with?(real, dir <> "/") and
             File.regular?(real),
           do: {:ok, real},
           else: {:error, "#{path} isn't in the app's temporary files."}
    end
  end

  # Where the capabilities leave their output: Android's cacheDir, iOS's
  # NSTemporaryDirectory().
  defp app_temp do
    with nil <- Application.get_env(:operator, :app_temp) do
      case Term.platform() do
        :android -> Mob.Storage.dir(:cache)
        :ios -> Mob.Storage.dir(:temp)
        _ -> nil
      end
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> nil
  end

  defp plain_name(name) when is_binary(name) do
    name = Path.basename(name)
    if name in ["", ".", ".."], do: nil, else: name
  end

  defp plain_name(_name), do: nil

  defp with_path(path, mode, fun) do
    with {:ok, abs, _root} <- resolve(path, mode), do: fun.(abs)
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @doc false
  # The path with every symlink along it resolved (as far as it exists).
  @spec real_path(Path.t()) :: Path.t()
  def real_path(path), do: path |> Path.split() |> follow([], 0)

  defp follow([], acc, _depth), do: join(acc)
  defp follow(_rest, acc, depth) when depth > 40, do: join(acc)

  defp follow([part | rest], acc, depth) do
    here = join(acc ++ [part])

    case :file.read_link(String.to_charlist(here)) do
      {:ok, target} ->
        target = to_string(target)
        base = if Path.type(target) == :absolute, do: target, else: Path.join(join(acc), target)
        follow(Path.split(Path.expand(base)) ++ rest, [], depth + 1)

      {:error, _} ->
        follow(rest, acc ++ [part], depth)
    end
  end

  defp join([]), do: "/"
  defp join(parts), do: Path.join(parts)
end
