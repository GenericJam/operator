defmodule Operator.Dyn.Showcase.Phone.Camera do
  @moduledoc """
  Takes a photo with the system camera (`MobCamera.capture_photo/2`) and
  picks photos from the gallery (`MobPhotos.pick/2`), and shows them.

  The camera needs `:camera` (`Mob.Permissions.request/2`; the answer comes
  as `{:permission, :camera, :granted | :denied}`). The gallery picker runs
  outside the app and needs no permission. Results come to `handle_info/2`:
  `{:camera, :photo, %{path:, width:, height:}}`, `{:camera, :cancelled}`,
  `{:photos, :picked, items}`, `{:photos, :cancelled}`. The paths are
  temporary files; an `:image` node shows a local path as it is.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @max_pick 4

  def entry,
    do: %{
      slug: :camera,
      name: "Camera & photos",
      category: "Phone",
      order: 2,
      description: "Take a photo with the camera or pick some from the gallery.",
      api: "MobCamera, MobPhotos, Mob.Permissions"
    }

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       permission: :unknown,
       photos: [],
       status: "Take a photo (asks for the camera first) or pick from the gallery."
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      permission_note(assigns.permission),
      Kit.gap(12),
      status_line(assigns.status),
      Kit.gap(12),
      Kit.grid([button("Take photo", :take), button("Pick photos", :pick)]),
      Kit.gap(16)
      | Enum.flat_map(assigns.photos, &photo/1)
    ])
  end

  defp permission_note(:granted), do: Kit.muted("✓ Camera allowed.")

  defp permission_note(:denied),
    do:
      Kit.muted(
        "✗ Camera denied. The phone won't ask again: allow it in Settings › Apps › Operator › " <>
          "Permissions. Picking from the gallery still works."
      )

  defp permission_note(_unknown), do: Kit.muted("The camera asks for permission the first time.")

  defp status_line(text),
    do: %{
      type: :text,
      props: %{text: text, text_size: :lg, text_color: :on_surface},
      children: []
    }

  defp photo(p) do
    [
      %{
        type: :image,
        props: %{src: p.path, width: 320, height: 240, content_mode: "fit", corner_radius: 8},
        children: []
      },
      Kit.gap(4),
      Kit.muted(describe(p)),
      Kit.gap(12)
    ]
  end

  defp describe(p) do
    [p.from, dims(p), bytes(p.size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp dims(%{width: w, height: h}) when is_integer(w) and w > 0, do: "#{w}×#{h}"
  defp dims(_p), do: nil

  defp bytes(n) when is_integer(n) and n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp bytes(n) when is_integer(n), do: "#{div(n, 1024)} KB"
  defp bytes(_n), do: nil

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

  # The camera: permission first, then the capture.
  defp widget({:tap, :take}, %{assigns: %{permission: :granted}} = socket), do: capture(socket)

  defp widget({:tap, :take}, socket) do
    case native(socket, &Mob.Permissions.request(&1, :camera)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Asking for the camera…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:permission, :camera, :granted}, socket),
    do: socket |> Mob.Socket.assign(permission: :granted) |> capture()

  defp widget({:permission, :camera, _denied}, socket),
    do: Mob.Socket.assign(socket, permission: :denied, status: "No camera, no photo.")

  defp widget({:camera, :photo, %{path: path} = shot}, socket) do
    p = %{from: "Camera", path: path, width: shot[:width], height: shot[:height], size: nil}
    Mob.Socket.assign(socket, photos: [p | socket.assigns.photos], status: "Photo taken.")
  end

  defp widget({:camera, :cancelled}, socket),
    do: Mob.Socket.assign(socket, status: "The camera was closed without a photo.")

  # The gallery: the system picker, no permission.
  defp widget({:tap, :pick}, socket) do
    case native(socket, &MobPhotos.pick(&1, max: @max_pick, types: [:image])) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Pick up to #{@max_pick} photos…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:photos, :picked, items}, socket) do
    picked =
      for %{path: path} = item <- items do
        %{
          from: "Gallery",
          path: path,
          width: item[:width],
          height: item[:height],
          size: item[:size]
        }
      end

    Mob.Socket.assign(socket,
      photos: picked ++ socket.assigns.photos,
      status: "Picked #{length(picked)}."
    )
  end

  defp widget({:photos, :cancelled}, socket),
    do: Mob.Socket.assign(socket, status: "Nothing picked.")

  defp widget(_message, socket), do: socket

  defp capture(socket) do
    case native(socket, &MobCamera.capture_photo(&1, quality: :medium)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Opening the camera…")
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
