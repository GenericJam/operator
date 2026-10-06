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

  `ctx[:file_roots]` replaces the roots (tests); otherwise the workspace is
  under `ctx[:data_dir]` or `Operator.Paths.data_dir/0`.
  """

  alias Operator.Core.Term

  @type root :: %{
          name: String.t(),
          path: Path.t(),
          access: :read_write | :read,
          about: String.t()
        }

  @shared "/storage/emulated/0"

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
