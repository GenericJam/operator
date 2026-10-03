defmodule Operator.Core.Dyn.Samples do
  @moduledoc """
  Sample Dyn sources (`priv/dyn_samples/*.ex.txt`), embedded at build time:
  the diagnostics screen stages and proposes them to prove the pipeline
  (check, compile, selftest) on the phone, as the agent's own sources will
  go through it.
  """

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on the device (see Operator.App.migrations_dir/0).
  # credo:disable-for-next-line
  @dir Path.expand("../../../../priv/dyn_samples", __DIR__)
  @samples (for f <- Path.wildcard(Path.join(@dir, "*.ex.txt")) do
              @external_resource f
              {Path.basename(f, ".ex.txt"), File.read!(f)}
            end)
           |> Map.new()

  @doc "The staging path (`<name>.ex`) and source of sample `name`."
  @spec get(String.t()) :: {String.t(), String.t()}
  def get(name), do: {name <> ".ex", Map.fetch!(@samples, name)}

  @spec names() :: [String.t()]
  def names, do: @samples |> Map.keys() |> Enum.sort()
end
