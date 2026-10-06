defmodule Operator.Core.Tools.FileList do
  @moduledoc "Core tool: the places files may be used, or what's in a directory."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.FileTool

  @max_entries 500

  @impl true
  def name, do: "file_list"

  @impl true
  def description,
    do:
      "List a directory: each entry's name, size and modification time, directories first. " <>
        "Without a path, lists the places files may be used (your workspace; on Android the " <>
        "phone's shared storage: Download, DCIM, Documents, ...). A relative path is in the " <>
        "workspace."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string", "description" => "Directory to list."}},
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(%{"path" => path}, ctx) when is_binary(path) and path != "" do
    with {:ok, dir, _root} <- FileTool.resolve(path, :read, ctx) do
      list(dir)
    end
  end

  def run(_args, ctx), do: {:ok, "Places files may be used:\n" <> FileTool.roots_text(ctx)}

  defp list(dir) do
    case File.ls(dir) do
      {:ok, []} ->
        {:ok, "#{dir} is empty."}

      {:ok, names} ->
        entries = names |> Enum.map(&entry(dir, &1)) |> Enum.sort_by(&{not &1.dir?, &1.name})
        shown = Enum.take(entries, @max_entries)
        more = length(entries) - length(shown)
        tail = if more > 0, do: "\n… and #{more} more", else: ""

        {:ok,
         "#{dir} (#{length(entries)} entries)\n" <> Enum.map_join(shown, "\n", &line/1) <> tail}

      {:error, reason} ->
        {:error, FileTool.posix(reason, dir)}
    end
  end

  defp entry(dir, name) do
    case File.stat(Path.join(dir, name), time: :posix) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        %{name: name, dir?: type == :directory, size: size, mtime: mtime}

      {:error, _} ->
        %{name: name, dir?: false, size: nil, mtime: nil}
    end
  end

  defp line(%{dir?: true} = e), do: "#{e.name}/  #{time(e.mtime)}"
  defp line(%{size: nil} = e), do: "#{e.name}  (unreadable)"
  defp line(e), do: "#{e.name}  #{FileTool.size(e.size)}  #{time(e.mtime)}"

  defp time(nil), do: ""

  defp time(posix),
    do: posix |> DateTime.from_unix!() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
