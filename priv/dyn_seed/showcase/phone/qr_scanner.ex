defmodule Operator.Dyn.Showcase.Phone.QrScanner do
  @moduledoc """
  Scans a QR code or barcode (`MobScanner.scan/2`: a full-screen camera
  view that closes by itself on the first code) and copies the text
  (`Mob.Clipboard.put/2`).

  The scanner needs `:camera` (`Mob.Permissions.request/2`; the answer
  comes as `{:permission, :camera, :granted | :denied}`). The scan ends in
  one of `{:scan, :result, %{type:, value:}}`, `{:scan, :cancelled}`,
  `{:scan, :permission_denied}` or `{:scan, :not_available}`.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  def entry,
    do: %{
      slug: :qr_scanner,
      name: "QR scanner",
      category: "Phone",
      order: 3,
      description: "Scan a QR code or barcode and copy what it says.",
      api: "MobScanner, Mob.Clipboard, Mob.Permissions"
    }

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       permission: :unknown,
       result: nil,
       status: "Scan opens the camera (it asks for permission the first time)."
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      permission_note(assigns.permission),
      Kit.gap(12),
      status_line(assigns.status),
      Kit.gap(12),
      Kit.grid(buttons(assigns)),
      Kit.gap(16)
      | result(assigns.result)
    ])
  end

  defp permission_note(:granted), do: Kit.muted("✓ Camera allowed.")

  defp permission_note(:denied),
    do:
      Kit.muted(
        "✗ Camera denied. The phone won't ask again: allow it in Settings › Apps › Operator › " <>
          "Permissions, then come back."
      )

  defp permission_note(_unknown), do: Kit.muted("Scanning needs the camera.")

  defp status_line(text),
    do: %{
      type: :text,
      props: %{text: text, text_size: :lg, text_color: :on_surface},
      children: []
    }

  defp buttons(%{result: nil}), do: [button("Scan", :scan)]
  defp buttons(_assigns), do: [button("Scan again", :scan), button("Copy", :copy)]

  defp result(nil), do: []

  defp result(%{type: type, value: value}) do
    [
      Kit.muted("#{type}:"),
      Kit.gap(4),
      Kit.code_block(value)
    ]
  end

  defp button(label, tag) do
    %{
      type: :button,
      props: %{
        text: label,
        background: :surface_raised,
        text_color: :on_surface,
        padding: :space_sm,
        weight: 1,
        on_tap: {self(), tag}
      },
      children: []
    }
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:tap, :scan}, %{assigns: %{permission: :granted}} = socket), do: scan(socket)

  defp widget({:tap, :scan}, socket) do
    case native(socket, &Mob.Permissions.request(&1, :camera)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Asking for the camera…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:permission, :camera, :granted}, socket),
    do: socket |> Mob.Socket.assign(permission: :granted) |> scan()

  defp widget({:permission, :camera, _denied}, socket),
    do: Mob.Socket.assign(socket, permission: :denied, status: "No camera, no scanning.")

  defp widget({:scan, :result, %{value: value} = code}, socket) do
    type = code |> Map.get(:type, "code") |> to_string()
    Mob.Socket.assign(socket, result: %{type: type, value: to_string(value)}, status: "Scanned.")
  end

  defp widget({:scan, :cancelled}, socket),
    do: Mob.Socket.assign(socket, status: "Closed without a code.")

  defp widget({:scan, :permission_denied}, socket),
    do: Mob.Socket.assign(socket, permission: :denied, status: "No camera, no scanning.")

  defp widget({:scan, :not_available}, socket),
    do: Mob.Socket.assign(socket, status: "The scanner couldn't open on this phone.")

  defp widget({:tap, :copy}, %{assigns: %{result: %{value: value}}} = socket) do
    case native(socket, &Mob.Clipboard.put(&1, value)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Copied.")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget(_message, socket), do: socket

  defp scan(socket) do
    case native(socket, &MobScanner.scan(&1, formats: [:qr, :ean13, :code128])) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Point the camera at a code…")
      :unavailable -> unavailable(socket)
    end
  end

  # A native call; where the NIF isn't there the screen says so instead of crashing.
  defp native(socket, call) do
    {:ok, call.(socket)}
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> :unavailable
  end

  defp unavailable(socket), do: Mob.Socket.assign(socket, status: "Not available on this device.")
end
