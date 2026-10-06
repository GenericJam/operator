defmodule Operator.Core.Tools.FileWrite do
  @moduledoc "Core tool: write (or append to) a file, creating its directory."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.FileTool

  @impl true
  def name, do: "file_write"

  @impl true
  def description,
    do:
      "Write a file (see file_list for where; a relative path is in your workspace), creating " <>
        "missing directories. Replaces the file unless `append` is true. `encoding` \"base64\" " <>
        "writes bytes given as base64."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"},
        "append" => %{"type" => "boolean"},
        "encoding" => %{"type" => "string", "enum" => ["utf8", "base64"]}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(%{"path" => path, "content" => content} = args, ctx) when is_binary(content) do
    with {:ok, bytes} <- decode(content, args["encoding"]),
         {:ok, file, _root} <- FileTool.resolve(path, :write, ctx),
         :ok <- mkdir(Path.dirname(file)),
         :ok <- write(file, bytes, args["append"] == true) do
      verb = if args["append"] == true, do: "Appended #{byte_size(bytes)} bytes to", else: "Wrote"
      {:ok, "#{verb} #{file} (now #{FileTool.size(File.stat!(file).size)})."}
    end
  end

  def run(_args, _ctx), do: {:error, "file_write needs a path and content."}

  defp decode(content, "base64") do
    case Base.decode64(content, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "content isn't valid base64."}
    end
  end

  defp decode(content, _utf8), do: {:ok, content}

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, FileTool.posix(reason, dir)}
    end
  end

  defp write(file, bytes, append?) do
    case File.write(file, bytes, if(append?, do: [:append], else: [])) do
      :ok -> :ok
      {:error, reason} -> {:error, FileTool.posix(reason, file)}
    end
  end
end
