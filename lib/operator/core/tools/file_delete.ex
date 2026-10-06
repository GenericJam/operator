defmodule Operator.Core.Tools.FileDelete do
  @moduledoc """
  Core tool: delete a file or an empty directory; a whole directory tree
  only inside the workspace. In shared storage (the user's photos and
  downloads) a recursive delete is refused, so text the agent read can't
  steer it into wiping DCIM in one call.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Tools.FileTool

  @impl true
  def name, do: "file_delete"

  @impl true
  def description,
    do:
      "Delete a file or an empty directory. A directory with everything in it (`recursive`: " <>
        "true) only inside your workspace; in shared storage delete the files one at a time. " <>
        "There is no undo: say what you're deleting first if the user didn't name it."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "recursive" => %{"type" => "boolean"}},
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(%{"path" => path} = args, ctx) do
    with {:ok, target, root} <- FileTool.resolve(path, :write, ctx) do
      cond do
        target == Files.real_path(root.path) ->
          {:error, "#{target} is the #{root.name} root itself; delete what's inside instead."}

        not File.dir?(target) ->
          delete_file(target)

        args["recursive"] != true ->
          delete_dir(target)

        root.name != "workspace" ->
          {:error,
           "#{target} is a directory in #{root.name}, and a whole directory is deleted only " <>
             "inside the workspace: delete its files one at a time (then the empty directory)."}

        true ->
          delete_tree(target)
      end
    end
  end

  def run(_args, _ctx), do: {:error, "file_delete needs a path."}

  defp delete_dir(target) do
    case File.rmdir(target) do
      :ok ->
        {:ok, "Deleted #{target}."}

      {:error, reason} when reason in [:eexist, :enotempty] ->
        {:error,
         "#{target} is a directory with things in it: pass recursive: true to delete it and " <>
           "its contents (workspace only)."}

      {:error, reason} ->
        {:error, FileTool.posix(reason, target)}
    end
  end

  defp delete_tree(target) do
    case File.rm_rf(target) do
      {:ok, gone} -> {:ok, "Deleted #{target} (#{length(gone)} files and directories)."}
      {:error, reason, at} -> {:error, FileTool.posix(reason, at)}
    end
  end

  defp delete_file(target) do
    case File.rm(target) do
      :ok -> {:ok, "Deleted #{target}."}
      {:error, reason} -> {:error, FileTool.posix(reason, target)}
    end
  end
end
