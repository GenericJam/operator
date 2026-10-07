defmodule Operator.Dyn.Showcase.Phone.Share do
  @moduledoc """
  Phone widget: the system share sheet with text (`Mob.Share.text/2`):
  messages, mail, notes, any app that takes text. A link inside the text
  is offered as a link. No permission, and nothing comes back: the sheet
  doesn't say where the text went.

  `Mob.Share` shares plain text only; there is no file sharing to show.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Phone

  def entry do
    %{
      slug: :share,
      name: "Share",
      category: "Phone",
      order: 6,
      description: "Hand text to another app through the system share sheet.",
      api: "Mob.Share"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       text: "Made with Operator, the phone's own coding agent.",
       status: "Edit the text, then share it."
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <TextField
          value={@text}
          placeholder="What to share"
          lines={3}
          fill_width={true}
          on_change={{self(), :text}}
        />
        <Spacer size={12} />
        <Row fill_width={true}>
          <Button
            text="Share text"
            background={:primary}
            text_color={:on_primary}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :share}}
          />
          <Spacer size={12} />
          <Button
            text="Share a link"
            background={:surface_raised}
            text_color={:on_surface}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :share_link}}
          />
        </Row>
        <Spacer size={8} />
        <Text
          text="Plain text only: Mob.Share has no file sharing."
          text_size={:sm}
          text_color={:muted}
        />
      </Column>
      """
    ])
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:change, :text, text}, socket), do: Mob.Socket.assign(socket, :text, text)

  defp widget({:tap, :share}, socket) do
    case String.trim(socket.assigns.text) do
      "" -> Mob.Socket.assign(socket, :status, "Type something to share first.")
      text -> share(socket, text)
    end
  end

  defp widget({:tap, :share_link}, socket),
    do: share(socket, "The Elixir language: https://elixir-lang.org")

  defp widget(_message, socket), do: socket

  defp share(socket, text) do
    socket
    |> Mob.Share.text(text)
    |> Mob.Socket.assign(:status, "Share sheet opened (it doesn't report where the text went).")
  rescue
    _ in [ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket, :status, "There's no share sheet on this device.")
  end
end
