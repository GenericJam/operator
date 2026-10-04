defmodule Operator.Dyn.Showcase.GalleryScreen do
  @moduledoc """
  The gallery index, Operator's default front: every component grouped by
  category (`Operator.Dyn.Showcase`). Tapping one opens its screen.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.ThemeBar

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(_assigns) do
    groups = Showcase.by_category()
    count = groups |> Enum.flat_map(fn {_, entries} -> entries end) |> length()

    body =
      [
        Kit.top_bar(ThemeBar.bar()),
        Kit.gap(16),
        Kit.page_header("🧩  Components", "#{count} component#{if count == 1, do: "", else: "s"}")
      ] ++ Enum.flat_map(groups, &category_block/1) ++ [Kit.gap(24)]

    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{type: :column, props: %{background: :background, padding: :space_lg}, children: body}
      ]
    }
  end

  defp category_block({category, entries}) do
    [Kit.gap(20), Kit.section_label(category)] ++
      Enum.flat_map(entries, fn e ->
        [Kit.gap(8), Kit.component_row(e.name, Map.get(e, :description), {:open, e.slug})]
      end)
  end

  def handle_info({:tap, {:set_theme, key}}, socket), do: {:noreply, ThemeBar.set(key, socket)}

  def handle_info({:tap, {:open, slug}}, socket) do
    case Showcase.get(slug) do
      nil -> {:noreply, socket}
      entry -> {:noreply, Mob.Socket.push_screen(socket, entry.module)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
