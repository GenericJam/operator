defmodule Operator.Dyn.Showcase.Phone do
  @moduledoc """
  The page every phone widget of the library draws
  (`Operator.Dyn.Showcase.Phone.*`, the category "Phone"): the theme bar, a
  header, "use this", the widget itself, a line naming the APIs it uses,
  and back. Each widget is a working screen of its own (permission asked
  where the API needs one, results arriving in its `handle_info/2`), meant
  to be copied (`dyn_copy`) and changed.

  Usage in a widget:

      def render(assigns), do: Phone.page(entry(), [ ...the widget's nodes... ])

      def handle_info(message, socket) do
        case Phone.handle(message, socket) do
          {:ok, socket} -> {:noreply, socket}
          :pass -> widget_info(message, socket)
        end
      end
  """

  alias Operator.Dyn.Showcase
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.ThemeBar

  @doc "The page around `children` (node maps) for the widget `entry`."
  def page(entry, children) do
    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_lg},
          children:
            [
              Kit.top_bar(ThemeBar.bar()),
              Kit.gap(16),
              Kit.page_header(entry.name, Map.get(entry, :description)),
              Kit.gap(12),
              Kit.use_this_button(entry.slug),
              Kit.gap(20)
            ] ++
              children ++
              [
                Kit.gap(20),
                Kit.muted("Uses " <> Map.get(entry, :api, "Mob")),
                Kit.gap(12),
                Kit.page_actions(entry.slug)
              ]
        }
      ]
    }
  end

  @doc """
  The page's own events (back, use this, the theme bar): `{:ok, socket}`,
  or `:pass` for the widget's.
  """
  def handle({:tap, :back}, socket), do: {:ok, Mob.Socket.pop_screen(socket)}

  def handle({:tap, {:use_this, slug}}, socket) do
    _ = Showcase.use_this(slug)
    {:ok, socket}
  end

  def handle({:tap, {:set_theme, key}}, socket), do: {:ok, ThemeBar.set(key, socket)}
  def handle(_message, _socket), do: :pass
end
