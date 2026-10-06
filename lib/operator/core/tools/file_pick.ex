defmodule Operator.Core.Tools.FilePick do
  @moduledoc """
  Core tool: the user picks files with the system document picker
  (`Mob.Files.pick/2`: Files on iOS, the storage picker on Android, so
  iCloud Drive, Google Drive, Downloads, ...). Each is copied into the
  workspace's `inbox/`; the agent gets its path, a text file's text, a
  picture to look at. The same pick as the chat's `[attach] › file`
  (`Operator.Core.Attachments.pick_files/2`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Attachments

  @impl true
  def name, do: "file_pick"

  @impl true
  def description,
    do:
      "Let the user pick files (any app's documents: Files/iCloud on iOS, Downloads/Drive on " <>
        "Android). Each is copied into your workspace's inbox/; you get its path, a text " <>
        "file's text (read the rest with file_read), a picture to look at. `types` narrows " <>
        ~s|the picker: extensions ("pdf", "csv"), MIME types ("text/*") or "images", "video", | <>
        ~s|"audio", "pdf", "text". The user can cancel.|

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

    types
    |> Attachments.pick_files(ctx)
    |> Attachments.tool_result("Picked (kept in your workspace's inbox/):")
  end
end
