defmodule Operator.Dyn.Showcase.Phone.Bluetooth do
  @moduledoc """
  A bounded Bluetooth scan: the devices nearby, for 12 seconds at most.

  The two platforms scan different radios. Android discovers Bluetooth
  Classic devices (`MobBluetooth.start_discovery/1`: name, address, paired
  or not; no signal strength) once the `:bluetooth_connect` permission
  ("Nearby devices", plus precise location on Android 11 and below) is
  granted. iOS has no Classic API, so it scans BLE
  (`MobBluetooth.ble_scan/2`: name and signal strength) and asks for
  Bluetooth by itself on the first scan.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @scan_ms 12_000
  @max_devices 50

  def entry do
    %{
      slug: :bluetooth,
      name: "Bluetooth",
      category: "Phone",
      order: 1,
      description: "Scan for nearby Bluetooth devices: name, address, signal.",
      api: "MobBluetooth, Mob.Permissions"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       platform: socket.__mob__.platform,
       permission: :unknown,
       # The running scan's timeout ref; nil when idle.
       scan: nil,
       devices: [],
       status: "Tap Scan to look for devices nearby."
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Row fill_width={true}>
          <Button
            text={if @scan, do: "Scanning…", else: "Scan"}
            on_tap={{self(), :scan}}
            disabled={@scan != nil}
            weight={1}
          />
          <Spacer size={12} />
          <Button
            text="Stop"
            on_tap={{self(), :stop}}
            disabled={@scan == nil}
            background={:surface_raised}
            text_color={:on_surface}
            weight={1}
          />
        </Row>
        <Spacer size={16} />
        <Column :for={device <- @devices} fill_width={true}>
          {device_row(device)}
          <Spacer size={8} />
        </Column>
      </Column>
      """,
      Kit.gap(8),
      Kit.muted(hint(assigns.platform))
    ])
  end

  defp device_row(device) do
    ~MOB"""
    <Box background={:surface} padding={:space_sm} corner_radius={:radius_sm} fill_width={true}>
      <Row fill_width={true}>
        <Column weight={1}>
          <Text text={name(device.name)} text_size={:base} text_color={:on_surface} max_lines={1} />
          <Text text={device.detail} text_size={:sm} text_color={:muted} max_lines={1} />
        </Column>
        <Text text={rssi(device.rssi)} text_size={:sm} text_color={:primary} />
      </Row>
    </Box>
    """
  end

  defp hint(:ios),
    do: "iOS scans Bluetooth Low Energy: headphones that only speak Classic won't show."

  defp hint(_android),
    do: "Android discovers Bluetooth Classic devices that are in pairing mode or discoverable."

  defp name(name) when name in [nil, ""], do: "(no name)"
  defp name(name), do: name

  defp rssi(nil), do: ""
  defp rssi(dbm), do: "#{dbm} dBm"

  # ── events ──

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, bluetooth(message, socket)}
    end
  end

  def terminate(_reason, socket) do
    _ = stop_scan(socket)
    :ok
  end

  # iOS asks for Bluetooth itself on the first scan; Android needs the
  # permission first (asked every time until granted: a denial still answers).
  defp bluetooth({:tap, :scan}, %{assigns: %{platform: :ios}} = socket), do: start_scan(socket)

  defp bluetooth({:tap, :scan}, %{assigns: %{permission: :granted}} = socket),
    do: start_scan(socket)

  defp bluetooth({:tap, :scan}, socket) do
    socket
    |> Mob.Permissions.request(:bluetooth_connect)
    |> Mob.Socket.assign(:status, "Asking for the Nearby devices permission…")
  end

  defp bluetooth({:permission, :bluetooth_connect, :granted}, socket),
    do: socket |> Mob.Socket.assign(:permission, :granted) |> start_scan()

  defp bluetooth({:permission, :bluetooth_connect, :denied}, socket) do
    Mob.Socket.assign(socket,
      permission: :denied,
      status:
        "Permission denied. Allow it in Settings → Apps → Operator → Permissions " <>
          "(Nearby devices, and precise Location), then scan again."
    )
  end

  defp bluetooth({:tap, :stop}, socket), do: stop_scan(socket)
  defp bluetooth({:scan_timeout, ref}, %{assigns: %{scan: ref}} = socket), do: stop_scan(socket)

  defp bluetooth({:bt, started}, socket) when started in [:discovery_started, :ble_scan_started],
    do: Mob.Socket.assign(socket, :status, "Scanning…")

  defp bluetooth({:bt, ended}, socket)
       when ended in [:discovery_finished, :discovery_cancelled, :ble_scan_stopped],
       do: Mob.Socket.assign(socket, scan: nil, status: found(socket.assigns.devices))

  # Android (Classic): one message per device found.
  defp bluetooth({:bt, :discovered, device}, socket) do
    detail = if device[:bonded], do: device.address <> " · paired", else: device.address
    put_device(socket, %{id: device.address, name: device[:name], detail: detail, rssi: nil})
  end

  # iOS (BLE): one message per advertisement, so the same device repeats.
  defp bluetooth({:bt, :ble_device, device}, socket),
    do:
      put_device(socket, %{id: device.id, name: device.name, detail: device.id, rssi: device.rssi})

  defp bluetooth({:bt, :error, error}, socket),
    do: Mob.Socket.assign(socket, scan: nil, status: error_text(reason(error)))

  defp bluetooth(_message, socket), do: socket

  defp start_scan(socket) do
    case scan(socket) do
      %Mob.Socket{} = socket ->
        ref = make_ref()
        Process.send_after(self(), {:scan_timeout, ref}, @scan_ms)
        Mob.Socket.assign(socket, scan: ref, devices: [], status: "Scanning…")

      {:error, :unsupported} ->
        Mob.Socket.assign(socket, :status, error_text(:unsupported))
    end
  end

  defp scan(%{assigns: %{platform: :ios}} = socket), do: MobBluetooth.ble_scan(socket)
  defp scan(socket), do: MobBluetooth.start_discovery(socket)

  defp stop_scan(%{assigns: %{scan: nil}} = socket), do: socket

  defp stop_scan(socket) do
    _ =
      if socket.assigns.platform == :ios,
        do: MobBluetooth.ble_stop_scan(socket),
        else: MobBluetooth.cancel_discovery(socket)

    Mob.Socket.assign(socket, scan: nil, status: found(socket.assigns.devices))
  end

  # Updates a device already listed in place (BLE repeats), appends a new one.
  defp put_device(socket, device) do
    devices = socket.assigns.devices

    devices =
      case Enum.find_index(devices, &(&1.id == device.id)) do
        nil -> Enum.take(devices ++ [device], @max_devices)
        i -> List.replace_at(devices, i, device)
      end

    Mob.Socket.assign(socket, :devices, devices)
  end

  defp found([]), do: "No devices found. Put one in pairing mode and scan again."
  defp found([_]), do: "Found 1 device."
  defp found(devices), do: "Found #{length(devices)} devices."

  defp reason(%{reason: reason}), do: reason
  defp reason(reason), do: reason

  defp error_text(:location_permission_required),
    do: "Discovery needs precise location: allow Location (Precise) for Operator in Settings."

  defp error_text(:location_disabled),
    do:
      "Location is off. Android only discovers devices with Location on: turn it on and scan again."

  defp error_text(:permission_denied),
    do: "The Nearby devices permission is off: Settings → Apps → Operator → Permissions."

  defp error_text(off) when off in [:adapter_disabled, :powered_off],
    do: "Bluetooth is off. Turn it on and scan again."

  defp error_text(:unauthorized),
    do: "Bluetooth access is off for Operator: Settings → Operator → Bluetooth."

  defp error_text(none) when none in [:no_adapter, :unsupported],
    do: "This device has no Bluetooth to scan with (an emulator has none)."

  defp error_text(reason), do: "Bluetooth error: #{inspect(reason)}"
end
