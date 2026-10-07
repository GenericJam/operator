defmodule Operator.Dyn.Showcase.Phone.AudioRecorder do
  @moduledoc """
  Records from the microphone and plays the recording back (`Mob.Audio`).

  The flow: ask for `:microphone` (`Mob.Permissions.request/2`; the answer
  comes as `{:permission, :microphone, :granted | :denied}`), record (a
  one-second tick shows the time; the recording stops itself after
  `@max_seconds`), stop (the file comes as `{:audio, :recorded, %{path:,
  duration:}}`), play it (`{:audio, :playback_finished, _}` when done) and
  keep it: the recording is a temporary file, `Operator.Core.Files.keep/1`
  copies it into the workspace. Where the audio NIF is missing the status
  line says so.
  """
  use Mob.Screen

  alias Operator.Core.Files
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @max_seconds 60

  def entry,
    do: %{
      slug: :audio_recorder,
      name: "Audio recorder",
      category: "Phone",
      order: 1,
      description: "Record from the microphone, see the time, play it back.",
      api: "Mob.Audio, Mob.Permissions, Operator.Core.Files"
    }

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       permission: :unknown,
       state: :idle,
       seconds: 0,
       recording: nil,
       kept: nil,
       status: "Allow the microphone, then record."
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      permission_step(assigns.permission),
      Kit.gap(16),
      status_line(assigns.status),
      Kit.gap(12),
      Kit.grid(buttons(assigns)),
      Kit.gap(16)
      | recording_info(assigns)
    ])
  end

  defp permission_step(:granted), do: Kit.muted("✓ Microphone allowed.")

  defp permission_step(:denied),
    do:
      Kit.muted(
        "✗ Microphone denied. The phone won't ask again: allow it in Settings › Apps › " <>
          "Operator › Permissions, then come back."
      )

  defp permission_step(_unknown),
    do:
      Kit.column([
        Kit.muted("Recording needs the microphone."),
        Kit.gap(8),
        button("Allow microphone", :ask)
      ])

  defp status_line(text),
    do: %{
      type: :text,
      props: %{text: text, text_size: :lg, text_color: :on_surface},
      children: []
    }

  defp buttons(%{permission: :granted, state: :recording}), do: [button("■ Stop", :stop)]
  defp buttons(%{permission: :granted, state: :saving}), do: []

  defp buttons(%{permission: :granted, state: :playing}),
    do: [button("■ Stop playing", :stop_playing)]

  defp buttons(%{permission: :granted, recording: nil}), do: [button("● Record", :record)]

  defp buttons(%{permission: :granted, kept: nil}),
    do: [button("● Record again", :record), button("▶ Play", :play), button("Keep", :keep)]

  defp buttons(%{permission: :granted}),
    do: [button("● Record again", :record), button("▶ Play", :play)]

  defp buttons(_assigns), do: []

  defp recording_info(%{recording: nil}), do: [Kit.muted("No recording yet.")]

  defp recording_info(%{recording: rec, kept: kept}) do
    [Kit.muted("Last recording: #{seconds(rec.duration)}, #{rec.path}")] ++
      if(kept, do: [Kit.gap(4), Kit.muted("Kept as #{kept}")], else: [])
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

  # ── the permission ──

  defp widget({:tap, :ask}, socket) do
    case native(socket, &Mob.Permissions.request(&1, :microphone)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Asking…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:permission, :microphone, :granted}, socket),
    do: Mob.Socket.assign(socket, permission: :granted, status: "Ready to record.")

  defp widget({:permission, :microphone, _denied}, socket),
    do: Mob.Socket.assign(socket, permission: :denied, status: "No microphone, no recording.")

  # ── recording ──

  defp widget({:tap, :record}, socket) do
    case native(socket, &Mob.Audio.start_recording(&1, format: :aac)) do
      {:ok, socket} ->
        Process.send_after(self(), :tick, 1_000)

        Mob.Socket.assign(socket,
          state: :recording,
          seconds: 0,
          kept: nil,
          status: "Recording… 0 s"
        )

      :unavailable ->
        unavailable(socket)
    end
  end

  # One tick a second, only while recording; at @max_seconds it stops.
  defp widget(:tick, %{assigns: %{state: :recording, seconds: s}} = socket) do
    if s + 1 >= @max_seconds do
      stop(socket)
    else
      Process.send_after(self(), :tick, 1_000)
      Mob.Socket.assign(socket, seconds: s + 1, status: "Recording… #{s + 1} s")
    end
  end

  defp widget(:tick, socket), do: socket
  defp widget({:tap, :stop}, socket), do: stop(socket)

  defp widget({:audio, :recorded, %{path: path} = rec}, socket) do
    rec = %{path: path, duration: rec[:duration] || socket.assigns.seconds}

    Mob.Socket.assign(socket,
      state: :idle,
      recording: rec,
      status: "Recorded #{seconds(rec.duration)}."
    )
  end

  defp widget({:audio, :error, reason}, socket),
    do: Mob.Socket.assign(socket, state: :idle, status: "The recorder failed: #{inspect(reason)}")

  # ── playback ──

  defp widget({:tap, :play}, %{assigns: %{recording: %{path: path}}} = socket) do
    case native(socket, &Mob.Audio.play(&1, path)) do
      {:ok, socket} -> Mob.Socket.assign(socket, state: :playing, status: "Playing…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:tap, :stop_playing}, socket) do
    case native(socket, &Mob.Audio.stop_playback/1) do
      {:ok, socket} -> Mob.Socket.assign(socket, state: :idle, status: "Stopped.")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:audio, :playback_finished, _info}, socket),
    do: Mob.Socket.assign(socket, state: :idle, status: "Played to the end.")

  defp widget({:audio, :playback_error, info}, socket),
    do:
      Mob.Socket.assign(socket, state: :idle, status: "Can't play it: #{inspect(info[:reason])}")

  # ── keeping it ──

  defp widget({:tap, :keep}, %{assigns: %{recording: %{path: path}}} = socket) do
    case Files.keep(path) do
      {:ok, kept} -> Mob.Socket.assign(socket, kept: kept, status: "Kept in the workspace.")
      {:error, why} -> Mob.Socket.assign(socket, status: why)
    end
  end

  defp widget(_message, socket), do: socket

  defp stop(socket) do
    case native(socket, &Mob.Audio.stop_recording/1) do
      {:ok, socket} -> Mob.Socket.assign(socket, state: :saving, status: "Saving…")
      :unavailable -> unavailable(socket)
    end
  end

  # A native call; where the NIF isn't there (an emulator without the
  # capability, the host) the screen says so instead of crashing.
  defp native(socket, call) do
    {:ok, call.(socket)}
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> :unavailable
  end

  defp unavailable(socket),
    do: Mob.Socket.assign(socket, state: :idle, status: "Not available on this device.")

  defp seconds(s) when is_number(s), do: "#{Float.round(s * 1.0, 1)} s"
  defp seconds(_other), do: "? s"
end
