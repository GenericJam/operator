defmodule Operator.Core.Tools.FileCopy do
  @moduledoc """
  Core tool: copy or move a file or directory between the places files may
  be used: how the agent hands a file out (to Download on Android; on iOS
  the workspace itself is in the Files app) or brings one in.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Tools.FileTool

  @impl true
  def name, do: "file_copy"

  @impl true
  def description,
    do:
      "Copy (or with `move`: move) a file or directory. To give the user a file: on Android " <>
        "copy it to the shared storage's Download (or Documents, Pictures) where their apps " <>
        "find it; on iOS your workspace is already in the Files app (On My iPhone › Operator). " <>
        "Won't overwrite unless `overwrite` is true."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "from" => %{"type" => "string"},
        "to" => %{"type" => "string", "description" => "Destination path, or a directory."},
        "move" => %{"type" => "boolean"},
        "overwrite" => %{"type" => "boolean"}
      },
      "required" => ["from", "to"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(%{"from" => from, "to" => to} = args, ctx) do
    move? = args["move"] == true

    with {:ok, src, src_root} <- FileTool.resolve(from, if(move?, do: :write, else: :read), ctx),
         :ok <- not_root(src, src_root),
         {:ok, dest, _root} <- FileTool.resolve(to, :write, ctx),
         dest = if(File.dir?(dest), do: Path.join(dest, Path.basename(src)), else: dest),
         :ok <- not_inside(src, dest),
         :ok <- free(dest, args["overwrite"] == true),
         :ok <- mkdir(Path.dirname(dest)),
         :ok <- transfer(src, dest, move?) do
      {:ok, "#{if move?, do: "Moved", else: "Copied"} #{src} to #{dest}."}
    end
  end

  def run(_args, _ctx), do: {:error, "file_copy needs from and to."}

  defp not_root(path, %{path: root}) do
    if path == Files.real_path(root),
      do: {:error, "#{path} is a whole root; pick something inside it."},
      else: :ok
  end

  defp not_inside(src, dest) do
    if String.starts_with?(dest, src <> "/"),
      do: {:error, "Can't put #{src} inside itself."},
      else: :ok
  end

  defp free(dest, overwrite?) do
    if File.exists?(dest) and not overwrite?,
      do: {:error, "#{dest} already exists (pass overwrite: true to replace it)."},
      else: :ok
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, FileTool.posix(reason, dir)}
    end
  end

  defp transfer(src, dest, true) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      # Across file systems (the app's own storage and shared storage).
      {:error, :exdev} ->
        with :ok <- transfer(src, dest, false) do
          {:ok, _} = File.rm_rf(src)
          :ok
        end

      {:error, reason} ->
        {:error, FileTool.posix(reason, src)}
    end
  end

  defp transfer(src, dest, false) do
    case File.cp_r(src, dest) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, FileTool.posix(reason, path)}
    end
  end
end
