defmodule Operator.SelfMod.Samples do
  @moduledoc """
  Sample sources for proving on-device compilation, embedded at build time
  (they stand in for source the agent will write at runtime).
  """

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on the device (see Operator.App.migrations_dir/0).
  # credo:disable-for-next-line
  @dir Path.expand("../../../priv/selfmod_samples", __DIR__)
  @samples (for f <- Path.wildcard(Path.join(@dir, "*.ex.txt")) do
              @external_resource f
              {Path.basename(f, ".ex.txt"), File.read!(f)}
            end)
           |> Map.new()

  @spec get(String.t()) :: String.t()
  def get(name), do: Map.fetch!(@samples, name)

  @spec names() :: [String.t()]
  def names, do: Map.keys(@samples)
end
