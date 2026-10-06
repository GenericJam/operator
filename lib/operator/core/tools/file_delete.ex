defmodule Operator.Core.Tools.FileDelete do
  @moduledoc "Core tool: delete a file, or a directory with everything in it."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Tools.FileTool

  @impl true
  def name, do: "file_delete"

  @impl true
  def description,
    do:
      "Delete a file, or a directory and everything in it (only with `recursive`: true). " <>
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

        File.dir?(target) and args["recursive"] != true ->
          {:error,
           "#{target} is a directory: pass recursive: true to delete it and its contents."}

        true ->
          delete(target)
      end
    end
  end

  def run(_args, _ctx), do: {:error, "file_delete needs a path."}

  defp delete(target) do
    if File.dir?(target), do: delete_tree(target), else: delete_file(target)
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
