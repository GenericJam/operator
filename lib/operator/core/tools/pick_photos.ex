defmodule Operator.Core.Tools.PickPhotos do
  @moduledoc """
  Core tool: the user picks photos or videos from the phone's library; the
  model sees each photo (scaled down) with its size, when and where it was
  taken (`Operator.Core.Tools.Photos`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Term
  alias Operator.Core.Tools.PhoneTool
  alias Operator.Core.Tools.Photos

  @impl true
  def name, do: "pick_photos"

  @impl true
  def description,
    do:
      "Let the user pick up to `max` photos or videos from the phone's library; you see each " <>
        "photo, with its size, when and where it was taken (EXIF GPS when the file has it) " <>
        "and its path. The user can cancel. For the latest photos without asking the user " <>
        "to pick, use photos_recent."

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

    case PhoneTool.call(:pick_photos, %{max: max}, ctx, 175_000) do
      {:ok, :cancelled} ->
        {:ok, "The user cancelled the picker."}

      {:ok, []} ->
        {:ok, "Nothing was picked."}

      {:ok, items} when is_list(items) ->
        Photos.result(
          Enum.map(items, &item/1),
          heading(Map.get_lazy(ctx, :platform, &Term.platform/0)),
          ctx
        )

      {:error, _} = error ->
        error
    end
  end

  # Android's photo picker hands over copies without the location.
  defp heading(:android), do: "Picked (Android's picker removes GPS; photos_recent keeps it):"
  defp heading(_platform), do: "Picked:"

  # The picker gives the copied file's path and its type (mob_photos:
  # `%{path, type}` on iOS, a string type on Android); the size comes from
  # the file, the rest from the picture (Photos).
  defp item(item) do
    path = item[:path] || item[:uri]

    %{
      source: path,
      name: item[:display_name] || item[:name] || Path.basename(path || "?"),
      type: to_string(item[:type] || "image"),
      size: item[:size] || file_size(path)
    }
  end

  defp file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> nil
    end
  end

  defp file_size(_), do: nil

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{"max" => 1}, &1),
        {:ok, :cancelled},
        &(&1 == {:ok, "The user cancelled the picker."})
      )
end
