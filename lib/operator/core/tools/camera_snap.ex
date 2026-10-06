defmodule Operator.Core.Tools.CameraSnap do
  @moduledoc """
  Core tool: the agent takes a photo itself, with no one pressing a
  shutter (`MobCamera.snap/1`, headless: no preview, the camera opens,
  settles its exposure, takes one still and closes). The model sees the
  photo; it's kept in the workspace's `photos/`. The chat screen asks for
  the camera permission the first time (`Operator.Core.Phone`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "camera_snap"

  @impl true
  def description,
    do:
      "Take a photo yourself, right now, with no one touching the phone, and look at it: " <>
        ~s|`camera` "back" (default) or "front" (selfie side), `flash` "off" (default), | <>
        ~s|"on" or "auto". It's saved in your workspace's photos/. Operator must be on | <>
        "screen (Android won't open the camera for an app in the background). For the user " <>
        "to frame and take the shot themselves, use camera_photo."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "camera" => %{"type" => "string", "enum" => ["back", "front"]},
        "flash" => %{"type" => "string", "enum" => ["off", "on", "auto"]}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 120_000

  @impl true
  def run(args, ctx) do
    facing = if args["camera"] == "front", do: :front, else: :back
    flash = Map.get(%{"on" => :on, "auto" => :auto}, args["flash"], :off)

    case PhoneTool.call(:camera_snap, %{facing: facing, flash: flash}, ctx, 115_000) do
      {:ok, %{path: path} = photo} -> keep(path, photo, facing, ctx)
      {:error, _} = error -> error
    end
  end

  defp keep(path, photo, facing, ctx) do
    dir = Path.join(Files.workspace(ctx), "photos")
    File.mkdir_p!(dir)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    dest = Path.join(dir, "snap-#{stamp}-#{facing}.jpg")

    with :ok <- File.cp(path, dest),
         {:ok, jpeg} <- File.read(dest) do
      _ = File.rm(path)

      {:ok,
       {:images, [{"image/jpeg", jpeg}],
        "Photo from the #{facing} camera, #{photo[:width]}×#{photo[:height]}, saved to #{dest}."}}
    else
      {:error, reason} -> {:error, "The photo was taken but couldn't be kept: #{reason}"}
    end
  end

  @impl true
  def selftest do
    dir = Path.join(System.tmp_dir!(), "operator-snap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    shot = Path.join(dir, "shot.jpg")
    File.write!(shot, <<0xFF, 0xD8, 0xFF, 0xD9>>)

    try do
      PhoneTool.selftest(
        &run(%{}, Map.put(&1, :data_dir, dir)),
        {:ok, %{path: shot, width: 4, height: 3, facing: :back}},
        &match?({:ok, {:images, [{"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xD9>>}], _}}, &1)
      )
    after
      File.rm_rf(dir)
    end
  end
end
