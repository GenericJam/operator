defmodule Operator.Core.Tools.Location do
  @moduledoc "Core tool: the phone's current location (one fix; asks for the permission the first time)."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "location"

  @impl true
  def description,
    do:
      "Get the phone's current location: latitude, longitude, accuracy in metres, altitude. " <>
        "The first time, the user is asked to allow location access."

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 45_000

  @impl true
  def run(_args, ctx) do
    with {:ok, %{lat: lat, lon: lon} = fix} <- PhoneTool.call(:location, %{}, ctx, 40_000) do
      {:ok,
       "lat #{lat}, lon #{lon}, accuracy #{round_m(fix[:accuracy])} m, altitude #{round_m(fix[:altitude])} m\n" <>
         "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=16/#{lat}/#{lon}"}
    end
  end

  defp round_m(n) when is_number(n), do: round(n)
  defp round_m(_), do: "?"

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{}, &1),
        {:ok, %{lat: 45.5, lon: -73.6, accuracy: 12.4, altitude: 30.0}},
        &match?({:ok, "lat 45.5, lon -73.6, accuracy 12 m" <> _}, &1)
      )
end
