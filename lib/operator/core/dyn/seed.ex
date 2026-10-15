defmodule Operator.Core.Dyn.Seed do
  @moduledoc """
  Operator's seed: the Dyn sources an install starts from, embedded at
  build time from `priv/dyn_seed/` (`Application.app_dir/2` can't resolve
  priv/ on the device), installed and updated by `Rho.Dyn.Seed` (see it for
  the merge rules). It is the default front: `Operator.Dyn.WelcomeScreen`
  (links to the terminal and the component library), the component
  library (`Operator.Dyn.Showcase`: the Mishka Chelekom widget pages `mix
  mob.new` generates, adapted to the static check, and the phone
  capability widgets), and `Operator.Dyn.Front`, the front's settings
  (start screen, toggle symbol).

  Compiling it whole takes about half a minute on a Moto G 2021, and the
  front says so meanwhile. Installs made before the seed's files were
  recorded (Operator 1.0.x) shipped the 1.0 seed, whose digests are in
  `priv/dyn_seed_1_0.sha256` (`Rho.Dyn.Seed.start/2`'s `:legacy`).
  """

  alias Operator.Core.Front
  alias Rho.Dyn.Seed, as: Installer

  # Read at compile time and embedded, like Operator.Core.Dyn.Samples.
  # credo:disable-for-next-line
  @dir Path.expand("../../../../priv/dyn_seed", __DIR__)
  @sources (for f <- Path.wildcard(Path.join(@dir, "**/*.ex")) do
              @external_resource f
              {Path.relative_to(f, @dir), File.read!(f)}
            end)
           |> Map.new()
  # credo:disable-for-next-line
  @legacy_file Path.expand("../../../../priv/dyn_seed_1_0.sha256", __DIR__)
  @external_resource @legacy_file
  @legacy_digests @legacy_file
                  |> File.read!()
                  |> String.split("\n", trim: true)
                  |> Map.new(fn line ->
                    [digest, path] = String.split(line, "  ", parts: 2)
                    {path, digest}
                  end)
  @rationale "The default front: the welcome screen and the component library (the seed)"

  @spec sources() :: %{String.t() => String.t()}
  def sources, do: @sources

  @doc "What Operator 1.0.x installs shipped: path => sha256."
  @spec legacy_digests() :: %{String.t() => String.t()}
  def legacy_digests, do: @legacy_digests

  @spec rationale() :: String.t()
  def rationale, do: @rationale

  @doc "Is the seed being installed right now?"
  @spec running?() :: boolean()
  defdelegate running?(), to: Installer

  @doc """
  Installs (or updates) the seed in the background unless it's current
  (`Rho.Dyn.Seed.start/2`); the front redraws when it ends. `opts` are
  `Rho.Dyn.Seed.start/2`'s, over Operator's.
  """
  @spec start(keyword()) :: {:ok, pid()} | :ignore
  def start(opts \\ []) do
    Installer.start(
      @sources,
      Keyword.merge(
        [legacy: @legacy_digests, notify: &Front.refresh/0, rationale: @rationale],
        opts
      )
    )
  end
end
