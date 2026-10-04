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

  # The picker gives only the copied file's path and its type (mob_photos:
  # `%{path, type}` on iOS; Android adds width/height, both 0), so the name
  # and size come from that file.
  defp describe(item) do
    path = item[:path] || item[:uri]
    name = item[:display_name] || item[:name] || if(path, do: Path.basename(path), else: "?")

    "#{name} · #{item[:mime_type] || item[:type] || "?"} · #{size(item, path)} bytes · #{path || "?"}"
  end

  defp size(%{size: size}, _path) when is_integer(size), do: size

  defp size(_item, path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> "?"
    end
  end

  defp size(_item, _path), do: "?"

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{"max" => 2}, &1),
        {:ok, [%{display_name: "a.jpg", mime_type: "image/jpeg", size: 10, path: "/p/a.jpg"}]},
        &(&1 == {:ok, "a.jpg · image/jpeg · 10 bytes · /p/a.jpg"})
      )
end
