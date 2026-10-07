defmodule Operator.Dyn.Showcase.Phone.Clipboard do
  @moduledoc """
  Phone widget: the system clipboard (`Mob.Clipboard`). Copy puts the
  field's text on it (`put/2`); Paste reads it back (`get/1`, synchronous:
  `{:clipboard, :ok, text}` or `{:clipboard, :empty}`). No permission;
  Android only lets the app in front read the clipboard, and shows a
  "pasted from" notice when it does.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Phone

  def entry do
    %{
      slug: :clipboard,
      name: "Clipboard",
      category: "Phone",
      order: 7,
      description: "Copy the field's text to the clipboard, or paste what's on it.",
      api: "Mob.Clipboard"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       text: "Copied from Operator",
       status: "Copy puts the text on the clipboard; Paste reads it back.",
       pasted: nil
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
          placeholder="Text to copy"
          fill_width={true}
          on_change={{self(), :text}}
        />
        <Spacer size={12} />
        <Row fill_width={true}>
          <Button
            text="Copy"
            background={:primary}
            text_color={:on_primary}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :copy}}
          />
          <Spacer size={12} />
          <Button
            text="Paste"
            background={:surface_raised}
            text_color={:on_surface}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :paste}}
          />
        </Row>
        {pasted(@pasted)}
      </Column>
      """
    ])
  end

  defp pasted(nil), do: nil

  defp pasted(text) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={16} />
      <Text text="On the clipboard" text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <Box
        fill_width={true}
        background={:surface_raised}
        padding={:space_sm}
        corner_radius={:radius_sm}
        border_color={:border}
        border_width={1}
      >
        <Text text={text} text_size={:sm} text_color={:on_surface} />
      </Box>
    </Column>
    """
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:change, :text, text}, socket), do: Mob.Socket.assign(socket, :text, text)

  defp widget({:tap, :copy}, socket) do
    case socket.assigns.text do
      "" ->
        Mob.Socket.assign(socket, :status, "Type something to copy first.")

      text ->
        socket
        |> Mob.Clipboard.put(text)
        |> Mob.Socket.assign(:status, "Copied #{String.length(text)} characters.")
    end
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> unavailable(socket)
  end

  defp widget({:tap, :paste}, socket) do
    case Mob.Clipboard.get(socket) do
      {:clipboard, :ok, text} ->
        Mob.Socket.assign(socket,
          status: "Pasted #{String.length(text)} characters.",
          pasted: text
        )

      {:clipboard, :empty} ->
        Mob.Socket.assign(socket,
          status: "The clipboard is empty (or holds no text).",
          pasted: nil
        )
    end
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> unavailable(socket)
  end

  defp widget(_message, socket), do: socket

  defp unavailable(socket),
    do: Mob.Socket.assign(socket, :status, "There's no clipboard on this device.")
end
