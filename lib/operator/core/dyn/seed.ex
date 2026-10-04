defmodule Operator.Core.Dyn.Seed do
  @moduledoc """
  The seed: the Dyn sources an install starts from, embedded at build time
  from `priv/dyn_seed/` (`Application.app_dir/2` can't resolve priv/ on the
  device). It is the default front: the Mishka Chelekom widget gallery
  `mix mob.new` generates (mob_new 0.6.5's showcase templates rendered as
  `Operator.Dyn.*` and adapted to the static check: each component's page
  is a front screen of its own, the catalog is a list instead of a
  registry, no `use` macro, no dynamic atoms), and `Operator.Dyn.Front`, the
  front's settings (start screen, toggle symbol).

  `start/1` installs it once per install, in the background after the
  launch's Dyn step (`Operator.Core.Dyn.seed/3`): compiling it takes about
  half a minute on a Moto G 2021, and the front says so meanwhile. The seed
  becomes a generation like any other, so its screens are the agent's to
  change, and reverting to that generation restores the defaults.
  """

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Registry
  alias Operator.Core.Dyn.Store
  alias Operator.Core.Front

  require Logger

  # Read at compile time and embedded, like Operator.Core.Dyn.Samples.
  # credo:disable-for-next-line
  @dir Path.expand("../../../../priv/dyn_seed", __DIR__)
  @sources (for f <- Path.wildcard(Path.join(@dir, "**/*.ex")) do
              @external_resource f
              {Path.relative_to(f, @dir), File.read!(f)}
            end)
           |> Map.new()
  @rationale "The default front: the Mishka Chelekom widget gallery (the seed)"

  @spec sources() :: %{String.t() => String.t()}
  def sources, do: @sources

  @spec rationale() :: String.t()
  def rationale, do: @rationale

  @doc "Is the seed being installed right now?"
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Installs the seed in a process of its own (registered under this
  module's name) unless it was installed, or can't be now (safe mode, a
  proposal pending: the next launch tries again). When it ends, `notify`
  runs (the front redraws).
  """
  @spec start(atom(), (-> any())) :: {:ok, pid()} | :ignore
  def start(keeper \\ Dyn.Keeper, notify \\ &Front.refresh/0) do
    with false <- running?(),
         {:ok, %{dir: dir}} <- Registry.config(keeper),
         nil <- Store.seed(dir),
         %{mode: :normal, pending: nil} <- Dyn.status(keeper) do
      # Registered before it starts, so running?/0 says so from now on.
      {:ok, pid} = Task.start(fn -> receive(do: (:go -> install(keeper, notify))) end)
      Process.register(pid, __MODULE__)
      send(pid, :go)
      {:ok, pid}
    else
      _ -> :ignore
    end
  end

  defp install(keeper, notify) do
    # After a Core update the current generation rebuilds first: the seed
    # goes on top of it, and one compile at a time is all a phone manages.
    :ok = Dyn.await_rebuild(keeper)
    {us, result} = :timer.tc(fn -> Dyn.seed(@sources, @rationale, keeper) end)

    case result do
      {:ok, n} -> Logger.info("[dyn] seed installed as generation #{n} in #{div(us, 1000)} ms")
      {:error, reason} -> Logger.error("[dyn] seed not installed: #{inspect(reason, limit: 20)}")
    end

    # Unregistered first: the front, redrawing, mustn't see it still running.
    Process.unregister(__MODULE__)
    notify.()
  end
end
