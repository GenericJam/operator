defmodule Operator.Core.Dyn.Seed do
  @moduledoc """
  The seed: the Dyn sources an install starts from, embedded at build time
  from `priv/dyn_seed/` (`Application.app_dir/2` can't resolve priv/ on the
  device). It is the default front: `Operator.Dyn.WelcomeScreen` (links to
  the terminal and the component library), the component library
  (`Operator.Dyn.Showcase`: the Mishka Chelekom widget pages `mix mob.new`
  generates, adapted to the static check, and the phone capability
  widgets), and `Operator.Dyn.Front`, the front's settings (start screen,
  toggle symbol).

  `start/2` installs it in the background after the launch's Dyn step
  (`Operator.Core.Dyn.seed/3`): compiling it whole takes about half a
  minute on a Moto G 2021, and the front says so meanwhile. The seed
  becomes a generation like any other, so its screens are the agent's to
  change, and reverting to that generation restores the defaults.

  **A newer seed on a phone that has one** (an app update that changed
  `priv/dyn_seed/`). The install records each seed file's sha256 as it
  shipped (`Operator.Core.Dyn.Store.seed_files/1`). When this build's seed
  differs, it is installed again, merged three ways with what runs now
  (`merge/3`): a seed file the user (or the agent) never changed is
  replaced by the new one (or removed, when the new seed dropped it); a new
  seed file is added unless the user already has a file at that path; a
  file the user changed, deleted or wrote stays exactly as it is. So user
  edits are never lost, at the price that an edited seed file doesn't get
  the update (reverting to the seed's generation, or asking the agent,
  does). The merged generation goes through the whole check, compile and
  selftest; if it fails (an edited file relies on something the new seed
  changed), nothing changes and that seed is recorded as rejected, so it
  isn't retried every launch; the next app update with a different seed
  tries again. Installs made before the record existed (Operator 1.0.x)
  shipped the 1.0 seed, whose digests are recorded in
  `priv/dyn_seed_1_0.sha256`: the seed generation's own sources can't stand
  in for them, since that install merged the user's files into it.
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
  @digests Map.new(@sources, fn {path, source} ->
             {path, :sha256 |> :crypto.hash(source) |> Base.encode16(case: :lower)}
           end)
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

  @doc "Each seed file's sha256, as this build ships it."
  @spec digests() :: %{String.t() => String.t()}
  def digests, do: @digests

  @spec rationale() :: String.t()
  def rationale, do: @rationale

  @doc "Is the seed being installed right now?"
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  What the Dyn store at `dir` needs: `:install` (no seed yet), `{:update,
  shipped}` (an older seed is installed; `shipped` its files' digests as
  they shipped) or `:none` (this seed, or this seed was rejected there).
  """
  @spec needed(Path.t(), %{String.t() => String.t()}) ::
          :install | {:update, %{String.t() => String.t()}} | :none
  def needed(dir, digests \\ @digests) do
    case Store.seed(dir) do
      nil ->
        :install

      _n ->
        record = Store.seed_files(dir)
        shipped = record.files || @legacy_digests

        cond do
          shipped == digests -> :none
          record.rejected == version(digests) -> :none
          true -> {:update, shipped}
        end
    end
  end

  @doc """
  The sources to install: `seed` over `current` (what runs now), given
  `shipped` (path => sha256 of the seed files as the installed seed shipped
  them; `%{}` for a first install). See the moduledoc for the rules.
  """
  @spec merge(
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: %{String.t() => String.t()}
  def merge(current, shipped, seed) do
    [current, shipped, seed]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn path, acc ->
      case pick(Map.get(current, path), Map.get(shipped, path), Map.get(seed, path)) do
        nil -> acc
        source -> Map.put(acc, path, source)
      end
    end)
  end

  # Unchanged since it shipped: the new seed's (nil: dropped).
  defp pick(current, shipped, new) when is_binary(current) and is_binary(shipped) do
    if sha256(current) == shipped, do: new, else: current
  end

  # A seed file the user deleted stays deleted.
  defp pick(nil, shipped, _new) when is_binary(shipped), do: nil
  # The user's own file wins over a new seed file at its path.
  defp pick(current, nil, _new) when is_binary(current), do: current
  defp pick(nil, nil, new), do: new

  @doc """
  Installs (or updates) the seed in a process of its own (registered under
  this module's name) unless it's current, or can't be now (safe mode, a
  proposal pending: the next launch tries again). When it ends, `notify`
  runs (the front redraws).
  """
  @spec start(atom(), (-> any()), %{String.t() => String.t()}) :: {:ok, pid()} | :ignore
  def start(keeper \\ Dyn.Keeper, notify \\ &Front.refresh/0, sources \\ @sources) do
    digests = if sources == @sources, do: @digests, else: Map.new(sources, &digest/1)

    with false <- running?(),
         {:ok, %{dir: dir}} <- Registry.config(keeper),
         need when need != :none <- needed(dir, digests),
         %{mode: :normal, pending: nil} <- Dyn.status(keeper) do
      shipped = if match?({:update, _}, need), do: elem(need, 1), else: %{}
      job = %{keeper: keeper, dir: dir, sources: sources, digests: digests, shipped: shipped}
      # Registered before it starts, so running?/0 says so from now on.
      {:ok, pid} = Task.start(fn -> receive(do: (:go -> install(job, notify))) end)
      Process.register(pid, __MODULE__)
      send(pid, :go)
      {:ok, pid}
    else
      _ -> :ignore
    end
  end

  defp install(job, notify) do
    # After a Core update the current generation rebuilds first: the seed
    # goes on top of it, and one compile at a time is all a phone manages.
    :ok = Dyn.await_rebuild(job.keeper)
    merge = &merge(&1, job.shipped, job.sources)
    {us, result} = :timer.tc(fn -> Dyn.seed(merge, @rationale, job.keeper) end)
    ms = div(us, 1000)

    case result do
      {:ok, n} ->
        record(job.dir, job.digests, nil)
        Logger.info("[dyn] seed installed as generation #{n} in #{ms} ms")

      # Everything it would change is the user's: nothing to install.
      {:error, :no_changes} ->
        record(job.dir, job.digests, nil)
        Logger.info("[dyn] seed is current (the user's files kept)")

      {:error, %{stage: stage} = rejection} ->
        # Not retried until a different seed ships; the old one keeps running.
        record(job.dir, Store.seed_files(job.dir).files, version(job.digests))
        Logger.error("[dyn] seed rejected at #{stage}: #{inspect(rejection, limit: 20)}")

      {:error, reason} ->
        Logger.error("[dyn] seed not installed: #{inspect(reason, limit: 20)}")
    end

    # Unregistered first: the front, redrawing, mustn't see it still running.
    Process.unregister(__MODULE__)
    notify.()
  end

  defp record(dir, files, rejected) do
    case Store.put_seed_files(dir, files, rejected) do
      :ok -> :ok
      {:error, e} -> Logger.error("[dyn] can't record the seed's files: #{inspect(e)}")
    end
  end

  defp version(digests),
    do:
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(Enum.sort(digests)))
      |> Base.encode16(case: :lower)

  defp digest({path, source}), do: {path, sha256(source)}
  defp sha256(source), do: :sha256 |> :crypto.hash(source) |> Base.encode16(case: :lower)
end
