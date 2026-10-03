defmodule Operator.Core.KeepAlive do
  @moduledoc """
  Keeps the app running while an agent run is in progress, so a run goes on
  when the app is backgrounded (PLAN.md "Background processing"). Android:
  `mob_background`'s `dataSync` foreground service, which also keeps the
  network up (Android 15 cut a backgrounded app's network after ~60 s, see
  docs/SPIKE.md); iOS: its silent audio session.

  A separate process watching every loop `Operator.Core.Current` starts
  (`Operator.Core.Watcher`), so nothing here can take a loop down: the
  backend is turned on at the first `agent_start` and off `:grace_ms`
  (default 20 s) after the last run ended (`agent_end`, or its loop exited),
  so back-to-back runs don't flap the service and `Operator.Core.Voice` can
  finish the run-end line while the app is still kept up (on iOS the
  keep-alive's audio session is what lets speech play in the background).
  Calls happen only on those transitions.

  `mob_background` 0.1.2 can't change its notification text ("Running in
  background") and has no Stop action; showing the run's status there needs
  a plugin release.

  Options: `:backend` (`{module, arg}`, `Operator.Core.KeepAlive.Backend`;
  default `{Operator.Core.KeepAlive.MobBackground, []}`), `:grace_ms`,
  `:current` (the `Operator.Core.Current` server), `:name`.
  """
  use GenServer

  alias Operator.Core.Watcher

  require Logger

  @defaults [
    backend: {Operator.Core.KeepAlive.MobBackground, []},
    grace_ms: 20_000,
    current: Operator.Core.Current
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`%{on: boolean, running: [session_id]}`."
  @spec status(GenServer.server()) :: %{on: boolean(), running: [String.t()]}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      backend: opts[:backend],
      grace_ms: opts[:grace_ms],
      watch: Watcher.new(opts[:current]),
      running: MapSet.new(),
      on: false,
      grace: nil
    }

    {:ok, state, {:continue, :watch}}
  end

  @impl true
  def handle_continue(:watch, s), do: {:noreply, %{s | watch: Watcher.watch(s.watch)}}

  @impl true
  def handle_call(:status, _from, s),
    do: {:reply, %{on: s.on, running: MapSet.to_list(s.running)}, s}

  @impl true
  def handle_info({:operator_core, sid, %{type: :agent_start}}, s),
    do: {:noreply, sync(%{s | running: MapSet.put(s.running, sid)})}

  def handle_info({:operator_core, sid, %{type: :agent_end}}, s),
    do: {:noreply, sync(%{s | running: MapSet.delete(s.running, sid)})}

  def handle_info({:operator_core, _sid, _event}, s), do: {:noreply, s}

  def handle_info({:grace_over, token}, %{grace: {_timer, token}} = s),
    do: {:noreply, %{s | grace: nil, on: not call(s, :stop)}}

  def handle_info({:grace_over, _stale}, s), do: {:noreply, s}

  def handle_info(message, s) do
    case Watcher.handle(message, s.watch) do
      {:loop_down, sid, w} ->
        running =
          if Watcher.session?(w, sid), do: s.running, else: MapSet.delete(s.running, sid)

        {:noreply, sync(%{s | watch: w, running: running})}

      {_up_or_ok, _sid, w} ->
        {:noreply, %{s | watch: w}}

      {:ok, w} ->
        {:noreply, %{s | watch: w}}

      :ignore ->
        {:noreply, s}
    end
  end

  # Running: cancel a pending stop, turn on if off. Idle: stop after the grace period.
  defp sync(s) do
    cond do
      MapSet.size(s.running) > 0 ->
        s = cancel_grace(s)
        if s.on, do: s, else: %{s | on: call(s, :keep_alive)}

      s.on and s.grace == nil ->
        token = make_ref()
        %{s | grace: {Process.send_after(self(), {:grace_over, token}, s.grace_ms), token}}

      true ->
        s
    end
  end

  defp cancel_grace(%{grace: nil} = s), do: s

  defp cancel_grace(%{grace: {timer, _token}} = s) do
    Process.cancel_timer(timer)
    %{s | grace: nil}
  end

  # true when the call succeeded. A failing backend is logged, never raised:
  # this process keeps the subscriptions, and its restarts count against
  # Operator.Core's supervisor, which also holds the loops.
  defp call(%{backend: {mod, arg}}, fun) do
    case apply(mod, fun, [arg]) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("[keep_alive] #{fun} failed: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Logger.warning("[keep_alive] #{fun} raised: #{Exception.message(e)}")
      false
  end
end

defmodule Operator.Core.KeepAlive.Backend do
  @moduledoc "What `Operator.Core.KeepAlive` turns on and off. `arg` is the backend's own."

  @callback keep_alive(arg :: term()) :: :ok | {:error, term()}
  @callback stop(arg :: term()) :: :ok | {:error, term()}
end

defmodule Operator.Core.KeepAlive.MobBackground do
  @moduledoc """
  The `mob_background` plugin. On the host its NIF isn't loaded, so the
  calls return `{:error, :unavailable}`.
  """
  @behaviour Operator.Core.KeepAlive.Backend

  @impl true
  def keep_alive(_arg), do: nif(&MobBackground.keep_alive/0)

  @impl true
  def stop(_arg), do: nif(&MobBackground.stop/0)

  defp nif(fun) do
    fun.()
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end
end
