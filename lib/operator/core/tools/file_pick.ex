defmodule Operator.Core.Tools.FilePick do
  @moduledoc """
  Core tool: the user picks files with the system document picker
  (`Mob.Files.pick/2`: Files on iOS, the storage picker on Android, so
  iCloud Drive, Google Drive, Downloads, ...). Each is copied into the
  workspace's `inbox/` and the agent gets its path.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Tools.FileTool
  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "file_pick"

  @impl true
  def description,
    do:
      "Let the user pick files (any app's documents: Files/iCloud on iOS, Downloads/Drive on " <>
        "Android). Each is copied into your workspace's inbox/; you get the paths (read them " <>
        ~s|with file_read). `types` narrows the picker: extensions ("pdf", "csv"), MIME | <>
        ~s|types ("text/*") or "images", "video", "audio", "pdf", "text". The user can cancel.|

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"types" => %{"type" => "array", "items" => %{"type" => "string"}}},
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 300_000

  @groups %{
    "images" => :images,
    "video" => :video,
    "audio" => :audio,
    "pdf" => :pdf,
    "text" => :text,
    "any" => :any
  }

  @impl true
  def run(args, ctx) do
    types =
      case args["types"] do
        [_ | _] = list -> Enum.map(list, &Map.get(@groups, &1, &1))
        _ -> [:any]
      end

    case PhoneTool.call(:pick_file, %{types: types}, ctx, 295_000) do
      {:ok, :cancelled} -> {:ok, "The user cancelled the picker."}
      {:ok, []} -> {:ok, "Nothing was picked."}
      {:ok, items} when is_list(items) -> keep(items, ctx)
      {:error, _} = error -> error
    end
  end

  defp keep(items, ctx) do
    inbox = Path.join(Files.workspace(ctx), "inbox")
    File.mkdir_p!(inbox)

    lines =
      Enum.map(items, fn item ->
        src = item[:path]
        dest = unique(inbox, item[:name] || Path.basename(src))

        case File.cp(src, dest) do
          :ok ->
            _ = File.rm(src)
            "#{dest} · #{item[:mime] || "?"} · #{FileTool.size(File.stat!(dest).size)}"

          {:error, reason} ->
            "#{item[:name] || src}: couldn't copy it (#{FileTool.posix(reason, src)})"
        end
      end)

    {:ok, "Picked:\n" <> Enum.join(lines, "\n")}
  end

  # The picked name, or name-2, name-3, ... if the inbox has it already.
  defp unique(dir, name) do
    name = name |> Path.basename() |> String.replace(~r/[\/\x00]/, "_")
    base = Path.rootname(name)
    ext = Path.extname(name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> Path.join(dir, name)
      n -> Path.join(dir, "#{base}-#{n}#{ext}")
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end
end
