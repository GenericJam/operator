defmodule Operator.Core.Tools.PickPhotos do
  @moduledoc """
  Core tool: the user picks photos or videos from the phone's library; the
  model sees each photo (scaled down) with its size, when and where it was
  taken. The same pick as the chat's `[attach] › photo library`
  (`Operator.Core.Attachments.pick_photos/2`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Attachments
  alias Operator.Core.Term
  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "pick_photos"

  @impl true
  def description,
    do:
      "Let the user pick up to `max` photos or videos from the phone's library; you see each " <>
        "photo, with its size, when and where it was taken (EXIF GPS when the file has it) " <>
        "and its path (a copy in your workspace's inbox/). The user can cancel. For the " <>
        "latest photos without asking the user to pick, use photos_recent."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"max" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}},
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(args, ctx) do
    max = if is_integer(args["max"]) and args["max"] in 1..20, do: args["max"], else: 1
    heading = heading(Map.get_lazy(ctx, :platform, &Term.platform/0))
    max |> Attachments.pick_photos(ctx) |> Attachments.tool_result(heading)
  end

  # Android's photo picker hands over copies without the location.
  defp heading(:android), do: "Picked (Android's picker removes GPS; photos_recent keeps it):"
  defp heading(_platform), do: "Picked:"

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{"max" => 1}, &1),
        {:ok, :cancelled},
        &(&1 == {:ok, "The user cancelled."})
      )
end
