defmodule Operator.Core.Tools.PickPhotos do
  @moduledoc "Core tool: the user picks photos or videos from the phone's library."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "pick_photos"

  @impl true
  def description,
    do:
      "Let the user pick up to `max` photos or videos from the phone's library; " <>
        "returns each item's name, type, size and path. The user can cancel."

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
        {:ok, Enum.map_join(items, "\n", &describe/1)}

      {:error, _} = error ->
        error
    end
  end

  defp describe(item) do
    name = item[:display_name] || item[:name] || "?"

    "#{name} · #{item[:mime_type] || item[:type] || "?"} · #{item[:size] || "?"} bytes · #{item[:path] || item[:uri] || "?"}"
  end

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{"max" => 2}, &1),
        {:ok, [%{display_name: "a.jpg", mime_type: "image/jpeg", size: 10, path: "/p/a.jpg"}]},
        &(&1 == {:ok, "a.jpg · image/jpeg · 10 bytes · /p/a.jpg"})
      )
end
