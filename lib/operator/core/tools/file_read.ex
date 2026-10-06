defmodule Operator.Core.Tools.FileRead do
  @moduledoc """
  Core tool: read a file. Text comes as lines (numbered from `offset`);
  a picture comes as the picture, scaled down, with its metadata
  (`Operator.Core.Images`); anything else is described. A long result goes
  through the output budget like any tool's (`Operator.Core.Artifacts`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Images
  alias Operator.Core.Tools.FileTool

  @default_limit 2_000
  @max_limit 20_000

  @impl true
  def name, do: "file_read"

  @impl true
  def description,
    do:
      "Read a file (see file_list for where). Text: its lines, `offset` (1-based, default 1) " <>
        "and `limit` lines (default #{@default_limit}). A photo or picture: you see it " <>
        "(scaled down), with its size, when and where it was taken. Other binaries: their " <>
        "size and first bytes."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "offset" => %{"type" => "integer", "minimum" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
      },
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(%{"path" => path} = args, ctx) do
    with {:ok, file, _root} <- FileTool.resolve(path, :read, ctx),
         {:ok, %File.Stat{type: :regular, size: size}} <- stat(file) do
      cond do
        Images.picture?(file) -> picture(file, size, ctx)
        FileTool.text?(file) -> text(file, size, args)
        true -> binary(file, size)
      end
    end
  end

  def run(_args, _ctx), do: {:error, "file_read needs a path."}

  defp stat(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular}} = ok -> ok
      {:ok, %File.Stat{type: :directory}} -> {:error, "#{file} is a directory: use file_list."}
      {:ok, %File.Stat{type: type}} -> {:error, "#{file} is a #{type}, not a file."}
      {:error, reason} -> {:error, FileTool.posix(reason, file)}
    end
  end

  defp picture(file, size, ctx) do
    with {:ok, %{mime: mime, bytes: bytes, info: info}} <- Images.for_model(file, ctx) do
      {:ok,
       {:images, [{mime, bytes}],
        "#{file} (#{FileTool.size(size)}): #{Images.describe(Map.put_new(info, :size, size))}"}}
    end
  end

  defp text(file, size, args) do
    offset = max(args["offset"] || 1, 1)
    limit = min(args["limit"] || @default_limit, @max_limit)

    lines =
      file
      |> File.stream!(:line)
      |> Stream.with_index(1)
      |> Stream.drop(offset - 1)
      |> Enum.take(limit + 1)

    {shown, more?} =
      if length(lines) > limit, do: {Enum.take(lines, limit), true}, else: {lines, false}

    body = Enum.map_join(shown, "", fn {line, n} -> "#{n}\t#{line}" end)

    note =
      cond do
        shown == [] ->
          "[#{file} has fewer than #{offset} lines]"

        more? ->
          "\n[more after line #{offset + limit - 1}: read on with offset #{offset + limit}]"

        true ->
          ""
      end

    {:ok, "#{file} (#{FileTool.size(size)})\n" <> body <> note}
  end

  defp binary(file, size) do
    head =
      case File.open(file, [:read, :binary], &IO.binread(&1, 64)) do
        {:ok, bytes} when is_binary(bytes) -> Base.encode16(bytes, case: :lower)
        _ -> "?"
      end

    {:ok,
     "#{file}: binary, #{FileTool.size(size)}. First bytes (hex): #{head}\n" <>
       "Not shown as text. Copy it to shared storage (file_copy) for the user to open."}
  end
end
