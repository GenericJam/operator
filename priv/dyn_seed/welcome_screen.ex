defmodule Operator.Dyn.WelcomeScreen do
  @moduledoc """
  The default front's start screen (`Operator.Dyn.Front.start/0`): what
  the front is, and the two ways on from here, the terminal (where the
  agent is) and the component library (`Operator.Dyn.Showcase.GalleryScreen`).
  The user's own screens usually replace it as the start screen.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.GalleryScreen
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.ThemeBar

  def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :note, nil)}

  def render(assigns) do
    note = if assigns.note, do: [Kit.gap(12), Kit.muted(assigns.note)], else: []

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
              Kit.gap(24),
              Kit.page_header("Operator", "Your phone's own coding agent."),
              Kit.gap(16),
              text(
                "This is the front: the app you build with the agent. Screens you ask " <>
                  "for show up here once you approve them with the screen lock."
              ),
              Kit.gap(24),
              link("Open the terminal  →", :terminal, "Talk to the agent; sign in from [menu]."),
              Kit.gap(16),
              link(
                "Component library  →",
                :library,
                "Every widget, and the phone's capabilities, ready to copy."
              )
            ] ++
              note ++
              [
                Kit.gap(24),
                Kit.muted(
                  "The dial in the top-left corner switches between this front and the " <>
                    "terminal. Try asking: \"make a screen with a slider and a date picker\"."
                )
              ]
        }
      ]
    }
  end

  def handle_info({:tap, :terminal}, socket) do
    case Operator.Core.Terminal.open() do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, Mob.Socket.assign(socket, :note, "Tap the dial to open it.")}
    end
  end

  def handle_info({:tap, :library}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, GalleryScreen)}

  def handle_info({:tap, {:set_theme, key}}, socket), do: {:noreply, ThemeBar.set(key, socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp text(text) do
    %{type: :text, props: %{text: text, text_size: :base, text_color: :on_surface}, children: []}
  end

  defp link(label, tag, caption) do
    Kit.column([
      %{
        type: :button,
        props: %{
          text: label,
          background: :primary,
          text_color: :on_primary,
          text_size: :lg,
          padding: :space_md,
          fill_width: true,
          on_tap: {self(), tag}
        },
        children: []
      },
      Kit.gap(6),
      Kit.muted(caption)
    ])
  end
end
