defmodule Operator.Core.SenseToolsTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Phone
  alias Operator.Core.Tools.CameraSnap
  alias Operator.Core.Tools.PhotosRecent
  alias Operator.Core.Tools.Sensors

  @moduletag :tmp_dir

  # A chat screen stand-in: answers each request in order with `answers`,
  # reporting what was asked.
  defp host(answers) do
    test = self()

    spawn(fn ->
      Enum.each(answers, fn answer ->
        receive do
          {:phone_request, ref, from, action, args} ->
            send(test, {:asked, action, args})
            Phone.reply(from, ref, answer)
        after
          5_000 -> :ok
        end
      end)
    end)
  end

  describe "camera_snap" do
    test "the photo is kept in the workspace and shown to the model", %{tmp_dir: dir} do
      shot = Path.join(dir, "cache_snap.jpg")
      File.write!(shot, "jpeg-bytes")
      host = host([{:ok, %{path: shot, width: 1568, height: 1176, facing: :front}}])

      assert {:ok, {:images, [{"image/jpeg", "jpeg-bytes"}], text}} =
               CameraSnap.run(%{"camera" => "front", "flash" => "auto"}, %{
                 phone_host: host,
                 data_dir: dir
               })

      assert_received {:asked, :camera_snap, %{facing: :front, flash: :auto}}
      assert [kept] = Path.wildcard(Path.join(dir, "workspace/photos/snap-*-front.jpg"))
      assert File.read!(kept) == "jpeg-bytes"
      assert text == "Photo from the front camera:\n1. #{kept} · 10 B · 1568×1176 (shown)"
      refute File.exists?(shot)
    end

    test "defaults to the back camera without flash; errors pass through", %{tmp_dir: dir} do
      host = host([{:error, "This phone has no camera on that side (or it's a simulator)."}])

      assert {:error, "This phone has no camera" <> _} =
               CameraSnap.run(%{}, %{phone_host: host, data_dir: dir})

      assert_received {:asked, :camera_snap, %{facing: :back, flash: :off}}
      assert CameraSnap.selftest() == :ok
    end
  end

  defmodule FakeSensors do
    @moduledoc false
    # Stands in for Operator.Core.Sensors; behaviour set per test process.
    def list, do: {:ok, Process.get(:sensor_list)}

    def read(type, _timeout) do
      send(self(), {:read, type})

      case Process.get({:reading, type}) do
        nil -> {:error, :unavailable}
        fun when is_function(fun, 0) -> fun.()
        values -> {:ok, %{values: values, timestamp: 0, accuracy: 3}}
      end
    end

    def window(type, ms) do
      send(self(), {:window, type, ms})
      {:ok, for(v <- Process.get({:window, type}), do: %{values: v, timestamp: 0, accuracy: 3})}
    end

    def steps_today, do: Process.get(:steps).()
    def heading, do: {:ok, 93.4}

    def device,
      do: %{
        battery_level: 82,
        battery_state: :charging,
        thermal_state: :nominal,
        low_power_mode: false,
        # Mob.Device.network_state/0's real shape (a bare value crashed on it).
        network: %{transport: :wifi, online: true, validated: true, expensive: false},
        model: "moto g power (2021)",
        os_version: "11",
        platform: :android
      }
  end

  defp sensors(list) do
    Process.put(:sensor_list, Enum.map(list, &%{type: &1, name: "#{&1} sensor", vendor: "acme"}))
    %{sensors: FakeSensors}
  end

  describe "sensors" do
    test "the default reads device, motion, heading and the environment; absent ones say so" do
      ctx = sensors([:accelerometer, :gyroscope, :magnetic_field, :light, :proximity])
      Process.put({:reading, :accelerometer}, [0.12, 9.81, 0.3])
      Process.put({:reading, :gyroscope}, [0.0, 0.01, 0.0])
      Process.put({:reading, :magnetic_field}, [12.0, -30.5, 40.0])
      Process.put({:reading, :light}, [120.0])
      Process.put({:reading, :proximity}, [5.0])

      assert {:ok, text} = Sensors.run(%{}, ctx)

      assert text ==
               """
               battery: 82 % (charging); thermal: nominal; low power mode: off; network: wifi, online
               device: moto g power (2021), Android 11
               accelerometer: x 0.12, y 9.81, z 0.30 m/s²
               gyroscope: x 0.00, y 0.01, z 0.00 rad/s
               magnetic_field: x 12.00, y -30.50, z 40.00 µT
               pressure: this phone has no pressure (barometer) sensor
               light: 120.00 lx
               proximity: 5.00 cm (nothing near)
               heading: 93.4° from magnetic north (E), phone held flat\
               """

      refute_received {:read, :pressure}
    end

    test "pressure gives an altitude estimate; names and aliases map to types" do
      ctx = sensors([:pressure, :relative_humidity, "com.acme.sensor.uv"])
      Process.put({:reading, :pressure}, [899.0])
      Process.put({:reading, :relative_humidity}, [41.5])
      Process.put({:reading, "com.acme.sensor.uv"}, [3.0])

      assert {:ok, text} =
               Sensors.run(%{"read" => ["Barometer", "humidity", "com.acme.sensor.uv"]}, ctx)

      assert text ==
               "pressure: 899.00 hPa (≈ 998 m above sea level at standard sea-level pressure)\n" <>
                 "relative_humidity: 41.50 %\n" <>
                 "com.acme.sensor.uv: 3.00"
    end

    test "a window gives min, mean and max per axis" do
      ctx = sensors([:light])
      Process.put({:window, :light}, [[10.0], [30.0], [20.0]])

      assert {:ok, "light over 500 ms (3 readings): min 10.00 mean 20.00 max 30.00 lx"} =
               Sensors.run(%{"read" => ["light"], "window_ms" => 500}, ctx)

      assert_received {:window, :light, 500}
    end

    test "steps: asks for the activity permission when missing, then reads again" do
      ctx = sensors([:step_counter])
      calls = :counters.new(1, [])

      Process.put(:steps, fn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: {:error, :permission},
          else: {:ok, %{steps: 4_210, distance_m: 3012.4, floors_ascended: 2}}
      end)

      ctx = Map.put(ctx, :phone_host, host([{:ok, :granted}]))

      assert {:ok, "steps: 4210 today (since midnight, 3012 m, 2 floors up)"} =
               Sensors.run(%{"read" => ["steps"]}, ctx)

      assert_received {:asked, :permission, %{capability: :activity_recognition}}
    end

    test "steps on Android are since boot; a refused permission is reported" do
      ctx = sensors([:step_counter])
      Process.put(:steps, fn -> {:ok, %{since_boot: 1234}} end)

      assert {:ok, "steps: 1234 since the phone last booted" <> _} =
               Sensors.run(%{"read" => ["pedometer"]}, ctx)

      Process.put(:steps, fn -> {:error, :permission} end)
      denied = Map.put(ctx, :phone_host, host([{:error, "The user didn't allow it."}]))

      assert {:ok, "steps: The user didn't allow it."} =
               Sensors.run(%{"read" => ["steps"]}, denied)
    end

    test "list shows every sensor with its vendor" do
      ctx = sensors([:pressure, "com.acme.sensor.uv"])

      assert {:ok, "2 sensors:\n- pressure: pressure sensor (acme)\n- com.acme.sensor.uv: " <> _} =
               Sensors.run(%{"read" => ["list"]}, ctx)
    end
  end

  describe "photos_recent" do
    test "the newest photos come back as pictures with their metadata", %{tmp_dir: dir} do
      thumb = Path.join(dir, "t.jpg")

      items = [
        %{
          uri: "content://media/external/images/media/42",
          display_name: "IMG_42.jpg",
          size: 2_000_000,
          type: "image"
        },
        %{
          uri: "content://media/external/images/media/41",
          display_name: "IMG_41.jpg",
          size: 1_000_000,
          type: "image"
        }
      ]

      ctx = %{
        list_media: fn 2 -> {:ok, items} end,
        thumbnail: fn uri, _opts ->
          File.write!(thumb, uri)
          {:ok, %{path: thumb, width: 1568, height: 1176, taken_at: "2026-10-04T08:00:00Z"}}
        end
      }

      assert {:ok, {:images, [{"image/jpeg", uri42}, {"image/jpeg", uri41}], text}} =
               PhotosRecent.run(%{"count" => 2}, ctx)

      assert {uri42, uri41} ==
               {"content://media/external/images/media/42",
                "content://media/external/images/media/41"}

      assert text =~
               "The newest 2 photos:\n" <>
                 "1. IMG_42.jpg · content://media/external/images/media/42 · 1.9 MB · " <>
                 "1568×1176 · taken 2026-10-04T08:00:00Z · no GPS in the file (shown)\n2. IMG_41.jpg"
    end

    test "asks for photo access first; a refusal is the answer" do
      ctx = %{phone_host: host([{:error, "The user didn't allow access to their photos."}])}

      assert {:error, "The user didn't allow access to their photos."} =
               PhotosRecent.run(%{}, ctx)

      assert_received {:asked, :permission, %{capability: :media}}
    end

    test "the library's raw JSON reply becomes the items (a tool gets it undecoded)" do
      json =
        ~s([{"uri":"content://media/external/images/media/7","display_name":"a.jpg",) <>
          ~s("size":45812,"date_taken":1791264755000,"mime_type":"image/jpeg","type":"image"}])

      assert [
               %{
                 uri: "content://media/external/images/media/7",
                 display_name: "a.jpg",
                 size: 45_812,
                 date_taken: 1_791_264_755_000,
                 type: "image"
               }
             ] = PhotosRecent.listed(json)

      assert PhotosRecent.listed("not json") == []
    end
  end
end
