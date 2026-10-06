defmodule Operator.Core.Tools.PhotosRecent do
  @moduledoc """
  Core tool: the newest photos in the phone's library, without the user
  picking (`MobPhotos.list_media/2`, which needs the photo library
  permission: asked through the chat screen the first time). The model
  sees them with their metadata (`Operator.Core.Tools.Photos`).
  `ctx[:list_media]` (`(count -> {:ok, items} | {:error, text})`) replaces
  the library in tests.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.PhoneTool
  alias Operator.Core.Tools.Photos

  @impl true
  def name, do: "photos_recent"

  @impl true
  def description,
    do:
      "Look at the newest `count` photos in the phone's library (default 1, max 5), newest " <>
        "first, with when and where each was taken, without asking the user to pick. The " <>
        "first time, the user is asked to allow photo access."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}},
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(args, ctx) do
    count = if is_integer(args["count"]) and args["count"] in 1..5, do: args["count"], else: 1
    list = Map.get(ctx, :list_media, &list/1)

    with {:ok, :granted} <- permission(ctx),
         {:ok, items} <- list.(count) do
      case items do
        [] ->
          {:ok, "The photo library is empty (or Operator may only see some photos)."}

        items ->
          Photos.result(Enum.map(items, &item/1), "The newest #{length(items)} photos:", ctx)
      end
    end
  end

  defp permission(%{list_media: _}), do: {:ok, :granted}
  defp permission(ctx), do: PhoneTool.call(:permission, %{capability: :media}, ctx, 115_000)

  defp list(count) do
    MobPhotos.list_media(nil, type: :image, limit: count)

    # The tool runs outside a screen, so the reply comes undecoded: only a
    # Mob.Screen turns `{:mob_file_result, "media", "listed", json}` into
    # `{:media, :listed, items}`.
    receive do
      {:mob_file_result, "media", "listed", json} when is_binary(json) -> {:ok, listed(json)}
      {:media, :listed, items} when is_list(items) -> {:ok, items}
    after
      15_000 -> {:error, "The photo library didn't answer within 15 s."}
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] ->
      {:error, "The photo library isn't available in this build."}
  end

  @fields ~w(uri path display_name type size date_taken)

  @doc false
  # The JSON list_media delivers, as the atom-keyed items item/1 reads.
  @spec listed(binary()) :: [map()]
  def listed(json) do
    case JSON.decode(json) do
      {:ok, items} when is_list(items) -> for %{} = item <- items, do: known_fields(item)
      _ -> []
    end
  end

  defp known_fields(item),
    do: for({key, value} <- item, key in @fields, into: %{}, do: {String.to_atom(key), value})

  defp item(item) do
    %{
      source: item[:uri] || item[:path],
      name: item[:display_name] || "?",
      type: to_string(item[:type] || "image"),
      size: item[:size],
      taken: item[:date_taken]
    }
  end
end
