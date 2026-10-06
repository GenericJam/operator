defmodule Operator.Core.Tools.Sensors do
  @moduledoc """
  Core tool: read the phone's sensors (`Operator.Core.Sensors`): one
  sample, or a window of them summarised (min / mean / max). Asks for the
  activity permission (steps; motion data on iOS) through the chat screen
  when a sensor says it's missing, then tries once more.
  `ctx[:sensors]` replaces the backend in tests.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Term
  alias Operator.Core.Tools.PhoneTool

  # The standard types, by name (no atoms from the model's strings).
  @types ~w(accelerometer gyroscope magnetic_field pressure light proximity step_counter
            step_detector gravity linear_acceleration rotation_vector game_rotation_vector
            geomagnetic_rotation_vector relative_humidity ambient_temperature
            significant_motion heart_rate accelerometer_uncalibrated gyroscope_uncalibrated
            magnetic_field_uncalibrated hinge_angle)a
  @by_name Map.new(@types, &{Atom.to_string(&1), &1})
  @aliases %{
    "barometer" => :pressure,
    "air_pressure" => :pressure,
    "gyro" => :gyroscope,
    "magnetometer" => :magnetic_field,
    "compass" => "heading",
    "humidity" => :relative_humidity,
    "temperature" => :ambient_temperature,
    "pedometer" => "steps"
  }
  @summary [:accelerometer, :gyroscope, :magnetic_field, :pressure, :light, :proximity]

  @units %{
    accelerometer: "m/s²",
    gravity: "m/s²",
    linear_acceleration: "m/s²",
    accelerometer_uncalibrated: "m/s²",
    gyroscope: "rad/s",
    gyroscope_uncalibrated: "rad/s",
    magnetic_field: "µT",
    magnetic_field_uncalibrated: "µT",
    pressure: "hPa",
    light: "lx",
    proximity: "cm",
    relative_humidity: "%",
    ambient_temperature: "°C",
    step_counter: "steps",
    heart_rate: "bpm",
    hinge_angle: "°"
  }

  @impl true
  def name, do: "sensors"

  @impl true
  def description,
    do:
      "Read the phone's sensors. `read` names what to read (default: battery and device, " <>
        ~s|motion, compass heading, pressure, light, proximity): "all", "list" (every | <>
        ~s|sensor the phone has, with vendor and range), "device", "heading", "steps" | <>
        "(today's steps on iOS; steps since the phone booted on Android, which keeps no " <>
        "history; asks for the activity permission the first time), or a sensor type: " <>
        "accelerometer, gyroscope, magnetic_field, pressure (barometer, hPa), light (lux; " <>
        "Android only), proximity, gravity, linear_acceleration, rotation_vector, " <>
        "relative_humidity, ambient_temperature, step_counter, or any type `list` shows. " <>
        "`window_ms` (100-10000) samples that long and gives min/mean/max instead of one value."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "read" => %{"type" => "array", "items" => %{"type" => "string"}},
        "window_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => 10_000}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(args, ctx) do
    backend = Map.get(ctx, :sensors, Operator.Core.Sensors)
    window = args["window_ms"]
    window = if is_integer(window) and window in 100..10_000, do: window

    wanted =
      case args["read"] do
        [_ | _] = names -> Enum.map(names, &String.downcase/1)
        _ -> ["all"]
      end

    available = available(backend)

    lines =
      wanted
      |> Enum.flat_map(&expand(&1, available))
      |> Enum.uniq()
      |> Enum.map(&line(&1, backend, available, window, ctx))

    {:ok, Enum.join(lines, "\n")}
  end

  defp available(backend) do
    case backend.list() do
      {:ok, list} -> list
      {:error, _} -> nil
    end
  end

  defp expand("all", _available),
    do: ["device"] ++ Enum.map(@summary, &{:sensor, &1}) ++ ["heading"]

  defp expand("list", _available), do: ["list"]
  defp expand("device", _), do: ["device"]
  defp expand("battery", _), do: ["device"]
  defp expand("heading", _), do: ["heading"]
  defp expand("steps", _), do: ["steps"]

  defp expand(name, available) do
    case Map.get(@aliases, name) || Map.get(@by_name, name) do
      nil -> [{:sensor, vendor(name, available)}]
      type when is_atom(type) -> [{:sensor, type}]
      other -> expand(other, available)
    end
  end

  # A name the phone's list has as a vendor type, or the name as given.
  defp vendor(name, available) do
    Enum.find_value(available || [], name, fn
      %{type: type} when is_binary(type) -> if String.downcase(type) == name, do: type
      _ -> nil
    end)
  end

  defp line("list", _backend, nil, _window, _ctx),
    do: "list: the sensor plugin isn't available in this build"

  defp line("list", _backend, available, _window, _ctx) do
    rows =
      Enum.map(available, fn s ->
        extra =
          [s[:vendor], s[:unit], s[:max_range] && "max #{s[:max_range]}"]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(", ")

        "- #{s[:type]}: #{s[:name]}#{if extra != "", do: " (#{extra})"}"
      end)

    Enum.join(["#{length(available)} sensors:" | rows], "\n")
  end

  defp line("device", backend, _available, _window, _ctx) do
    d = backend.device()

    battery =
      case d[:battery_level] do
        n when is_number(n) -> "#{n} %#{state(d[:battery_state])}"
        _ -> "unknown"
      end

    "battery: #{battery}; thermal: #{d[:thermal_state] || "?"}; low power mode: " <>
      "#{on_off(d[:low_power_mode])}; network: #{d[:network] || "?"}\n" <>
      "device: #{d[:model] || "?"}, #{platform(d[:platform])} #{d[:os_version] || ""}"
  end

  defp line("heading", backend, _available, _window, _ctx) do
    case backend.heading() do
      {:ok, h} when is_number(h) ->
        "heading: #{Float.round(h, 1)}° from magnetic north (#{compass(h)}), phone held flat"

      {:ok, nil} ->
        "heading: no compass reading (no magnetometer, or it needs a figure-8 to calibrate)"

      {:error, why} ->
        "heading: #{reason(why)}"
    end
  end

  defp line("steps", backend, _available, _window, ctx) do
    case with_permission(fn -> backend.steps_today() end, ctx) do
      {:ok, %{steps: n} = s} ->
        dist = if is_number(s[:distance_m]), do: ", #{round(s[:distance_m])} m", else: ""

        floors =
          if is_integer(s[:floors_ascended]), do: ", #{s[:floors_ascended]} floors up", else: ""

        "steps: #{n} today (since midnight#{dist}#{floors})"

      {:ok, %{since_boot: n}} ->
        "steps: #{n} since the phone last booted (Android's step counter keeps no daily history)"

      {:error, why} ->
        "steps: #{reason(why)}"
    end
  end

  defp line({:sensor, type}, backend, available, window, ctx) do
    if available != nil and not Enum.any?(available, &(&1[:type] == type)) do
      "#{type}: this phone has no #{label(type)} sensor#{ios_note(type)}"
    else
      sample(type, backend, window, ctx)
    end
  end

  defp ios_note(:light) do
    if Term.platform() == :ios,
      do: " (iOS gives apps no ambient light reading)",
      else: ""
  end

  defp ios_note(_type), do: ""

  defp sample(type, backend, nil, ctx) do
    case with_permission(fn -> backend.read(type, 3_000) end, ctx) do
      {:ok, %{values: values}} -> "#{type}: #{values(type, values)}#{note(type, values)}"
      {:error, why} -> "#{type}: #{reason(why)}"
    end
  end

  defp sample(type, backend, window, ctx) do
    case with_permission(fn -> backend.window(type, window) end, ctx) do
      {:ok, []} ->
        "#{type}: no readings in #{window} ms (it reports on change only)"

      {:ok, readings} ->
        "#{type} over #{window} ms (#{length(readings)} readings): " <> stats(type, readings)

      {:error, why} ->
        "#{type}: #{reason(why)}"
    end
  end

  # A missing permission: ask through the chat screen, then once more.
  defp with_permission(fun, ctx) do
    case fun.() do
      {:error, :permission} ->
        case PhoneTool.call(:permission, %{capability: :activity_recognition}, ctx, 115_000) do
          {:ok, :granted} -> fun.()
          {:error, _} = error -> error
        end

      other ->
        other
    end
  end

  defp values(type, [v]), do: "#{num(v)} #{Map.get(@units, type, "")}" |> String.trim_trailing()

  defp values(type, values) do
    axes =
      case values do
        [_, _, _] -> ~w(x y z)
        _ -> Enum.map(1..length(values), &"v#{&1}")
      end

    Enum.zip_with(axes, values, &"#{&1} #{num(&2)}")
    |> Enum.join(", ")
    |> Kernel.<>(" " <> Map.get(@units, type, ""))
    |> String.trim_trailing()
  end

  defp stats(type, readings) do
    columns = readings |> Enum.map(& &1.values) |> Enum.zip_with(& &1)
    unit = Map.get(@units, type, "")
    xyz? = match?([_, _, _], columns)

    columns
    |> Enum.with_index()
    |> Enum.map_join("; ", fn {col, i} ->
      axis = if xyz?, do: Enum.at(~w(x y z), i) <> " ", else: ""
      mean = Enum.sum(col) / length(col)
      "#{axis}min #{num(Enum.min(col))} mean #{num(mean)} max #{num(Enum.max(col))}"
    end)
    |> Kernel.<>(" " <> unit)
    |> String.trim_trailing()
  end

  # Pressure → altitude by the standard atmosphere (the weather moves it).
  defp note(:pressure, [hpa | _]) when is_number(hpa) and hpa > 0 do
    m = 44_330 * (1 - :math.pow(hpa / 1013.25, 1 / 5.255))
    " (≈ #{round(m)} m above sea level at standard sea-level pressure)"
  end

  defp note(:proximity, [cm | _]) when is_number(cm),
    do: if(cm < 1, do: " (something is near the screen)", else: " (nothing near)")

  defp note(_type, _values), do: ""

  defp num(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp num(v), do: to_string(v)

  defp label(:pressure), do: "pressure (barometer)"
  defp label(:light), do: "ambient light"
  defp label(type), do: to_string(type)

  defp reason(:unavailable), do: "not available (no such sensor, or not on this platform)"
  defp reason(:unknown_type), do: "unknown sensor type (see `list`)"
  defp reason(:timeout), do: "no reading in time (some sensors report only on change)"
  defp reason(:history_unavailable), do: "no step history on this phone"
  defp reason(:permission), do: "the activity permission wasn't granted"
  defp reason(why) when is_binary(why), do: why
  defp reason(why), do: inspect(why)

  defp state(nil), do: ""
  defp state(s), do: " (#{s})"

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(_), do: "?"

  defp platform(:android), do: "Android"
  defp platform(:ios), do: "iOS"
  defp platform(_), do: ""

  @points ~w(N NE E SE S SW W NW)
  defp compass(h), do: Enum.at(@points, rem(round(h / 45), 8))
end
