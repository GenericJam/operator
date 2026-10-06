defmodule Operator.Core.Tools.Photos do
  @moduledoc """
  What the photo tools (`pick_photos`, `photos_recent`) share: each item
  as a picture for the model plus a line of metadata (`Operator.Core.Images`).
  """

  alias Operator.Core.Images
  alias Operator.Core.Tools.FileTool

  @max_pictures 5

  @doc """
  The tool result for `items` (each `%{source, name, type}` plus whatever
  else the plugin said): up to #{@max_pictures} pictures, one line each.
  """
  @spec result([map()], String.t(), map()) :: {:ok, term()}
  def result(items, heading, ctx) do
    {lines, pictures} =
      items
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {item, n}, pictures ->
        {line, picture} = item(item, n, length(pictures) < @max_pictures, ctx)
        {line, if(picture, do: [picture | pictures], else: pictures)}
      end)

    text = Enum.join([heading | lines], "\n")

    case Enum.reverse(pictures) do
      [] -> {:ok, text}
      pictures -> {:ok, {:images, pictures, text}}
    end
  end

  defp item(%{source: source} = item, n, show?, ctx) do
    base = "#{n}. #{item.name} · #{item.type}#{size(item)} · #{source}"

    cond do
      item.type == "video" ->
        {base <> " (a video: not shown)", nil}

      not show? ->
        {base <> " (not shown: #{@max_pictures} pictures per call)", nil}

      true ->
        case Images.for_model(source, ctx) do
          {:ok, %{mime: mime, bytes: bytes, info: info}} ->
            {base <> " · " <> Images.describe(info) <> " (shown)", {mime, bytes}}

          {:error, why} ->
            {base <> " (#{why})", nil}
        end
    end
  end

  defp size(%{size: size}) when is_integer(size) and size > 0, do: " · " <> FileTool.size(size)
  defp size(_), do: ""
end
