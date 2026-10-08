defmodule Operator.Dyn.Showcase.Phone.Midi do
  @moduledoc """
  The MIDI devices attached to the phone (USB, or Bluetooth MIDI once
  paired in the system settings), and a test note to the one you pick.

  MIDI needs no runtime permission. The list is asked for right after
  mount (the answer comes to `handle_info/2`) and on Refresh; iOS also
  reports plugging and unplugging. A note is a Note On now and its Note Off
  half a second later, on channel 1; Close releases the output.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @note 60
  @note_ms 500

  def entry do
    %{
      slug: :midi,
      name: "MIDI",
      category: "Phone",
      order: 3,
      description: "List MIDI devices and play a test note on one.",
      api: "MobMidi"
    }
  end

  def mount(_params, _session, socket) do
    send(self(), :refresh)

    {:ok,
     Mob.Socket.assign(socket,
       devices: [],
       # The output device id picked, and how its port is doing.
       output: nil,
       output_status: nil,
       status: "Looking for MIDI devices…",
       sent: nil
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Button
          text="Refresh"
          on_tap={{self(), :refresh}}
          background={:surface_raised}
          text_color={:on_surface}
        />
        <Spacer size={16} />
        <Column :for={device <- @devices} fill_width={true}>
          {device_row(device, @output)}
          <Spacer size={8} />
        </Column>
        <Column :if={@output} fill_width={true}>
          <Spacer size={8} />
          <Text
            text={output_line(@devices, @output, @output_status)}
            text_size={:base}
            text_color={:on_surface}
          />
          <Spacer size={12} />
          <Row fill_width={true}>
            <Button text="Play middle C" on_tap={{self(), :play}} weight={1} />
            <Spacer size={12} />
            <Button
              text="Close"
              on_tap={{self(), :close}}
              background={:surface_raised}
              text_color={:on_surface}
              weight={1}
            />
          </Row>
          <Spacer size={8} />
          <Text :if={@sent} text={@sent} text_size={:sm} text_color={:muted} />
        </Column>
      </Column>
      """,
      Kit.gap(8),
      Kit.muted("Tap a device that receives MIDI to send it a note.")
    ])
  end

  defp device_row(device, output) do
    props = %{
      background: :surface,
      padding: :space_sm,
      corner_radius: :radius_sm,
      fill_width: true,
      border_width: if(device.id == output, do: 2, else: 0),
      border_color: :primary
    }

    # Only a device that receives MIDI can be played.
    props =
      if device.direction in [:output, :both],
        do: Map.put(props, :on_tap, {self(), {:output, device.id}}),
        else: props

    body = ~MOB"""
    <Column fill_width={true}>
      <Text text={device.name || "(no name)"} text_size={:base} text_color={:on_surface} />
      <Text text={direction(device.direction)} text_size={:sm} text_color={:muted} />
    </Column>
    """

    %{type: :box, props: props, children: [body]}
  end

  defp direction(:input), do: "Sends MIDI to the phone (a keyboard, pads)"
  defp direction(:output), do: "Receives MIDI from the phone (a synth): tap to pick"
  defp direction(:both), do: "Sends and receives MIDI: tap to pick"

  defp output_line(devices, id, status) do
    name = Enum.find_value(devices, "device #{id}", &(&1.id == id && &1.name))
    "Output: #{name} (#{status})"
  end

  # ── events ──

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, midi(message, socket)}
    end
  end

  def terminate(_reason, socket) do
    _ = close(socket)
    :ok
  end

  defp midi(refresh, socket) when refresh in [:refresh, {:tap, :refresh}], do: list(socket)

  # iOS reports plugging and unplugging; the list is asked for again.
  defp midi({:midi, change, _}, socket) when change in [:device_added, :device_removed],
    do: list(socket)

  defp midi({:midi, :devices, payload}, socket) do
    devices = MobMidi.parse_devices(payload)
    Mob.Socket.assign(socket, devices: devices, status: found(devices))
  end

  defp midi({:tap, {:output, id}}, socket) do
    socket = close(socket)

    case MobMidi.open_output(socket, id) do
      %Mob.Socket{} = socket ->
        Mob.Socket.assign(socket, output: id, output_status: "opening…", sent: nil)

      {:error, reason} ->
        Mob.Socket.assign(socket, :status, "Can't open it: #{inspect(reason)}")
    end
  end

  defp midi({:midi, :opened, %{device: id}}, %{assigns: %{output: id}} = socket),
    do: Mob.Socket.assign(socket, :output_status, "ready")

  defp midi({:midi, :error, %{device: id, reason: reason}}, %{assigns: %{output: id}} = socket),
    do: Mob.Socket.assign(socket, :output_status, "error: #{reason}")

  # Sends before the port is open are queued and go out once it is.
  defp midi({:tap, :play}, %{assigns: %{output: id}} = socket) when id != nil do
    case MobMidi.send_note_on(socket, id, 0, @note, 100) do
      %Mob.Socket{} = socket ->
        Process.send_after(self(), {:note_off, id}, @note_ms)
        Mob.Socket.assign(socket, :sent, "Sent middle C (note #{@note}), channel 1.")

      {:error, reason} ->
        Mob.Socket.assign(socket, :sent, "Not sent: #{reason}.")
    end
  end

  defp midi({:note_off, id}, socket) do
    _ = MobMidi.send_note_off(socket, id, 0, @note, 0)
    socket
  end

  defp midi({:tap, :close}, socket), do: close(socket)
  defp midi(_message, socket), do: socket

  defp list(socket) do
    case MobMidi.list_devices(socket) do
      %Mob.Socket{} = socket -> Mob.Socket.assign(socket, :status, "Looking for MIDI devices…")
      {:error, :unsupported} -> Mob.Socket.assign(socket, :status, "There's no MIDI here.")
    end
  end

  defp close(%{assigns: %{output: nil}} = socket), do: socket

  defp close(socket) do
    _ = MobMidi.close(socket, socket.assigns.output)
    Mob.Socket.assign(socket, output: nil, output_status: nil, sent: nil)
  end

  defp found([]),
    do:
      "No MIDI devices. Plug in a USB MIDI keyboard or synth (or pair a Bluetooth MIDI one " <>
        "in Settings), then tap Refresh."

  defp found([_]), do: "1 MIDI device."
  defp found(devices), do: "#{length(devices)} MIDI devices."
end
