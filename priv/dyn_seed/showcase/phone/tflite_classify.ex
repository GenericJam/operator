defmodule Operator.Dyn.Showcase.Phone.TfliteClassify do
  @moduledoc """
  Classifies a photo with the bundled MobileNet (`Operator.Core.Tflite`:
  NNAPI on Android, Core ML on iOS, else XNNPACK on the CPU) and shows the
  top 3 ImageNet labels with their scores and the time each step took.

  The photo comes from the camera (`MobCamera.capture_photo/2`, after the
  `:camera` permission) or the gallery (`MobPhotos.pick/2`, no
  permission). The work runs in a `Task` (the screen stays responsive, and
  gives up after `@timeout_ms`): a small thumbnail of the photo
  (`MobPhotos.thumbnail/2`), kept in the workspace (`Operator.Core.Files.keep/1`)
  to read its bytes, decoded (`TfliteClassify.Jpeg`), center-cropped and
  scaled to the model's 128×128 input in [-1, 1], then the model is loaded,
  run and released. The 1001 class names are in `TfliteClassify.Labels`.
  """
  use Mob.Screen

  alias Operator.Core.Files
  alias Operator.Core.Tflite
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone
  alias Operator.Dyn.Showcase.Phone.TfliteClassify.Jpeg
  alias Operator.Dyn.Showcase.Phone.TfliteClassify.Labels

  @side 128
  @timeout_ms 30_000

  def entry,
    do: %{
      slug: :tflite_classify,
      name: "Image classifier",
      category: "Phone",
      order: 5,
      description:
        "Name what's in a photo with the bundled MobileNet, on the phone's accelerator.",
      api: "Operator.Core.Tflite, Nx, MobCamera, MobPhotos, Operator.Core.Files"
    }

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       permission: :unknown,
       photo: nil,
       task: nil,
       result: nil,
       status: "Take or pick a photo to classify."
     )}
  end

  def render(assigns) do
    Phone.page(
      entry(),
      [
        permission_note(assigns.permission),
        Kit.gap(12),
        status_line(assigns.status),
        Kit.gap(12),
        Kit.grid(buttons(assigns)),
        Kit.gap(16)
      ] ++ photo(assigns.photo) ++ result(assigns.result)
    )
  end

  defp permission_note(:denied),
    do:
      Kit.muted(
        "✗ Camera denied: allow it in Settings › Apps › Operator › Permissions. Picking a " <>
          "photo still works."
      )

  defp permission_note(_permission),
    do: Kit.muted("MobileNet v1 (ImageNet, 1000 classes) runs on the phone, nothing is sent.")

  defp status_line(text),
    do: %{
      type: :text,
      props: %{text: text, text_size: :lg, text_color: :on_surface},
      children: []
    }

  defp buttons(%{task: nil}), do: [button("Take photo", :take), button("Pick photo", :pick)]
  defp buttons(_working), do: []

  defp photo(nil), do: []

  defp photo(path),
    do: [
      %{
        type: :image,
        props: %{src: path, width: 256, height: 192, content_mode: "fit", corner_radius: 8},
        children: []
      },
      Kit.gap(12)
    ]

  defp result(nil), do: []

  defp result(r) do
    rows =
      for {label, score} <- r.top do
        %{
          type: :text,
          props: %{text: "#{percent(score)}  #{label}", text_size: :lg, text_color: :on_surface},
          children: []
        }
      end

    rows ++
      [
        Kit.gap(8),
        Kit.muted(
          "Decode #{r.decode_ms} ms · model load #{r.load_ms} ms · inference #{r.run_ms} ms " <>
            "on #{r.delegate}"
        )
      ]
  end

  defp percent(score), do: "#{Float.round(score * 100, 1)}%"

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

  # ── getting a photo ──

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
    do: Mob.Socket.assign(socket, permission: :denied, status: "No camera: pick a photo instead.")

  defp widget({:tap, :pick}, socket) do
    case native(socket, &MobPhotos.pick(&1, max: 1, types: [:image])) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Pick a photo…")
      :unavailable -> unavailable(socket)
    end
  end

  defp widget({:camera, :photo, %{path: path}}, socket), do: classify(socket, path)
  defp widget({:photos, :picked, [%{path: path} | _]}, socket), do: classify(socket, path)

  defp widget({:camera, :cancelled}, socket),
    do: Mob.Socket.assign(socket, status: "No photo taken.")

  defp widget({:photos, :cancelled}, socket),
    do: Mob.Socket.assign(socket, status: "Nothing picked.")

  defp widget({:photos, :picked, _nothing}, socket),
    do: Mob.Socket.assign(socket, status: "Nothing picked.")

  # ── the task's answer ──

  defp widget({ref, answer}, %{assigns: %{task: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    case answer do
      {:ok, result} ->
        Mob.Socket.assign(socket, task: nil, result: result, status: "Done.")

      {:error, why} ->
        Mob.Socket.assign(socket, task: nil, status: "Couldn't classify it: #{why}")
    end
  end

  defp widget({:timeout, ref}, %{assigns: %{task: %Task{ref: ref} = task}} = socket) do
    _ = Task.shutdown(task, :brutal_kill)
    Mob.Socket.assign(socket, task: nil, status: "Gave up after #{div(@timeout_ms, 1000)} s.")
  end

  defp widget(_message, socket), do: socket

  defp capture(socket) do
    case native(socket, &MobCamera.capture_photo(&1, quality: :medium)) do
      {:ok, socket} -> Mob.Socket.assign(socket, status: "Opening the camera…")
      :unavailable -> unavailable(socket)
    end
  end

  # One classification at a time, in a Task that can't take the screen
  # down with it (it answers {:error, why} instead of raising).
  defp classify(%{assigns: %{task: nil}} = socket, path) do
    task = Task.async(fn -> safely(fn -> run(path) end) end)
    Process.send_after(self(), {:timeout, task.ref}, @timeout_ms)
    Mob.Socket.assign(socket, task: task, photo: path, result: nil, status: "Classifying…")
  end

  defp classify(socket, _path), do: socket

  # ── the work (in the Task) ──

  defp run(path) do
    {decode_us, decoded} = :timer.tc(fn -> pixels(path) end)

    with {:ok, input} <- decoded,
         {load_us, {:ok, model, delegate}} <-
           :timer.tc(fn -> Tflite.load(Tflite.bundled_model_bytes()) end),
         {run_us, outputs} <- :timer.tc(fn -> Tflite.run(model, [input]) end) do
      :ok = Tflite.release(model)

      with {:ok, [scores | _]} <- outputs do
        {:ok,
         %{
           top: top(scores, 3),
           delegate: delegate,
           decode_ms: div(decode_us, 1000),
           load_ms: div(load_us, 1000),
           run_ms: div(run_us, 1000)
         }}
      end
    else
      {_us, {:error, why}} -> {:error, why}
      {:error, why} -> {:error, why}
    end
  end

  # The photo as the model's input: a thumbnail (no bigger than twice the
  # input), its JPEG decoded, the center square scaled to 128×128, values
  # in [-1, 1], as f32 bytes.
  defp pixels(path) do
    with {:ok, %{path: thumb}} <- MobPhotos.thumbnail(path, max_size: 2 * @side, quality: 95),
         {:ok, kept} <- Files.keep(thumb),
         {:ok, bytes} <- Files.read(kept),
         _ <- Files.rm(kept),
         {:ok, %{width: w, height: h, rgb: rgb}} <- Jpeg.decode(bytes) do
      side = min(w, h)

      rows =
        Nx.tensor(
          for i <- 0..(@side - 1), do: div(h - side, 2) + div((2 * i + 1) * side, 2 * @side)
        )

      cols =
        Nx.tensor(
          for i <- 0..(@side - 1), do: div(w - side, 2) + div((2 * i + 1) * side, 2 * @side)
        )

      input =
        rgb
        |> Nx.take(rows, axis: 0)
        |> Nx.take(cols, axis: 1)
        |> Nx.divide(127.5)
        |> Nx.subtract(1.0)
        |> Nx.as_type(:f32)
        |> Nx.to_binary()

      {:ok, input}
    end
  end

  # The `n` best classes as {label, score}.
  defp top(scores, n) do
    for(<<s::32-float-native <- scores>>, do: s)
    |> Enum.with_index()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(n)
    |> Enum.map(fn {score, i} -> {Labels.label(i), score} end)
  end

  defp safely(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, inspect(why)}
    end
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:error, "not available on this device (#{Exception.message(e) |> String.slice(0, 80)})"}

    e ->
      {:error, Exception.message(e)}
  end

  # A native call; where the NIF isn't there the screen says so instead of crashing.
  defp native(socket, call) do
    {:ok, call.(socket)}
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> :unavailable
  end

  defp unavailable(socket), do: Mob.Socket.assign(socket, status: "Not available on this device.")
end
