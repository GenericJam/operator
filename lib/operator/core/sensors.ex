defmodule Operator.Core.Sensors do
  @moduledoc """
  The phone's sensors for the `sensors` tool, one call each, answered in
  the calling process: `MobSensors` (every sensor the phone has: pressure,
  light, proximity, steps, humidity, ... plus the motion ones), the fused
  compass heading from `Mob.Motion`, and battery/device facts from
  `Mob.Device`. The tool takes another module with these functions
  (`ctx[:sensors]`) in tests.
  """

  alias Operator.Core.Term

  @type reading :: %{values: [float()], timestamp: integer(), accuracy: integer() | nil}
  @type type :: atom() | String.t()

  @callback list() :: {:ok, [map()]} | {:error, term()}
  @callback read(type(), timeout()) :: {:ok, reading()} | {:error, term()}
  @callback window(type(), pos_integer()) :: {:ok, [reading()]} | {:error, term()}
  @callback steps_today() ::
              {:ok, %{steps: non_neg_integer()} | %{since_boot: non_neg_integer()}}
              | {:error, term()}
  @callback heading() :: {:ok, float() | nil} | {:error, term()}
  @callback device() :: map()

  @behaviour __MODULE__

  @impl true
  def list do
    {:ok, MobSensors.list()}
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  @impl true
  def read(type, timeout) do
    case MobSensors.read(type, timeout_ms: timeout) do
      :ok ->
        receive do
          {:mob_sensors, :reading, ^type, reading} -> {:ok, reading}
          {:mob_sensors, :error, ^type, reason} -> {:error, reason}
        after
          timeout + 2_000 -> {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  @impl true
  def window(type, ms) do
    case MobSensors.start(type, interval_ms: 100) do
      :ok ->
        deadline = System.monotonic_time(:millisecond) + ms

        try do
          collect(type, deadline, [])
        after
          MobSensors.stop(type)
          flush(type)
        end

      {:error, _} = error ->
        error
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  defp collect(type, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {:mob_sensors, :reading, ^type, reading} -> collect(type, deadline, [reading | acc])
      {:mob_sensors, :error, ^type, reason} -> {:error, reason}
    after
      max(left, 0) -> {:ok, Enum.reverse(acc)}
    end
  end

  defp flush(type) do
    receive do
      {:mob_sensors, _, ^type, _} -> flush(type)
    after
      0 -> :ok
    end
  end

  @impl true
  def steps_today do
    case Term.platform() do
      :ios -> pedometer_today()
      _ -> since_boot()
    end
  end

  # iOS keeps a week of pedometer history: count from local midnight.
  defp pedometer_today do
    now = System.os_time(:millisecond)
    {_date, {h, m, s}} = :calendar.local_time()
    midnight = now - ((h * 60 + m) * 60 + s) * 1000

    case MobSensors.steps(midnight, now) do
      :ok ->
        receive do
          {:mob_sensors, :steps, result} -> result
        after
          10_000 -> {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  # Android's step counter counts from the last boot, with no history.
  defp since_boot do
    with {:ok, %{values: [n | _]}} <- read(:step_counter, 5_000),
         do: {:ok, %{since_boot: trunc(n)}}
  end

  @impl true
  def heading do
    Mob.Motion.start(nil, sensors: [:accelerometer, :magnetometer], interval_ms: 100)

    try do
      await_heading(System.monotonic_time(:millisecond) + 2_000)
    after
      Mob.Motion.stop(nil)
      flush_motion()
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  defp await_heading(deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {:motion, %{heading: h}} when is_number(h) -> {:ok, h * 1.0}
      {:motion, _} -> await_heading(deadline)
    after
      max(left, 0) -> {:ok, nil}
    end
  end

  defp flush_motion do
    receive do
      {:motion, _} -> flush_motion()
    after
      0 -> :ok
    end
  end

  @impl true
  def device do
    %{
      battery_level: safe(&Mob.Device.battery_level/0),
      battery_state: safe(&Mob.Device.battery_state/0),
      thermal_state: safe(&Mob.Device.thermal_state/0),
      low_power_mode: safe(&Mob.Device.low_power_mode?/0),
      network: safe(&Mob.Device.network_state/0),
      model: safe(&Mob.Device.model/0),
      os_version: safe(&Mob.Device.os_version/0),
      platform: Term.platform()
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
