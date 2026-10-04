defmodule Operator.Dyn.Showcase.Page do
  @moduledoc """
  The page every component screen draws (the generated app's
  `ComponentScreen`, one function per screen here): the theme bar, a header,
  each example (title, description, live preview, code), the props table
  and a back button, with the component's overlay (a drawer's panel, a
  dialog) over the whole page. `handle_info/4` routes the screen's events to
  its `handle/2` (taps, submits, focus) and `handle_change/3` (values,
  drags).
  """

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.ThemeBar

  def render(entry, examples, props, overlay, assigns) do
    page = %{
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
              Kit.gap(20)
            ] ++
              Enum.flat_map(examples, fn ex ->
                [
                  Kit.example_block(ex.title, ex.description, ex.render.(assigns), ex.code),
                  Kit.gap(16)
                ]
              end) ++
              props_section(props) ++
              [Kit.gap(8), Kit.back_button()]
        }
      ]
    }

    %{
      type: :box,
      props: %{fill_width: true, fill_height: true, background: :background},
      children: if(overlay, do: [page, overlay], else: [page])
    }
  end

  defp props_section([]), do: []

  defp props_section(props),
    do: [Kit.section_header("Props"), Kit.gap(12), Kit.props_table(props), Kit.gap(8)]

  def handle_info({:tap, {:set_theme, key}}, socket, _handle, _change),
    do: ThemeBar.set(key, socket)

  def handle_info({:tap, :back}, socket, _handle, _change), do: Mob.Socket.pop_screen(socket)
  def handle_info({:tap, tag}, socket, handle, _change), do: handle.(tag, socket)
  # A submit (return key) carries no payload: routed like a tap.
  def handle_info({:submit, tag}, socket, handle, _change), do: handle.(tag, socket)
  def handle_info({:focus, tag}, socket, handle, _change), do: handle.(tag, socket)
  def handle_info({:blur, tag}, socket, handle, _change), do: handle.(tag, socket)
  # Values from toggles, sliders, text fields...
  def handle_info({:change, tag, value}, socket, _handle, change), do: change.(tag, value, socket)
  # ...and positioned drags, which the component turns into its own value.
  def handle_info({:drag, tag, payload}, socket, _handle, change),
    do: change.(tag, payload, socket)

  def handle_info(_message, socket, _handle, _change), do: socket
end
