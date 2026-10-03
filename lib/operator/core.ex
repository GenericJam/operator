defmodule Operator.Core do
  @moduledoc """
  The fixed core (docs/DESIGN.md §1): the agent loop, sessions, core tools.
  Started by `Operator.Boot`; supervises the biometric approval and
  `Operator.Core.Dyn.Keeper` (which Dyn generation runs; `Operator.Boot`
  then loads it), the tool registry,
  the task supervisor tools run under, the loops, `Operator.Core.Current`
  (which session the app is showing; the latest one is resumed at boot),
  and the observers of its runs: `Operator.Core.KeepAlive` (keeps the app
  running in the background during a run) and `Operator.Core.Voice`
  (reads updates aloud).

  Config (`config :operator, ...`): `:default_model` (a req_llm spec,
  default `#{inspect("openrouter:anthropic/claude-haiku-4.5")}`), `:max_tokens` (4096).
  """
  use Supervisor

  alias Operator.Core.Dyn

  @default_model "openrouter:anthropic/claude-haiku-4.5"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Operator.Core.Dyn.Approval.Biometric,
      Operator.Core.Dyn.Keeper,
      Operator.Core.ToolRegistry,
      {Task.Supervisor, name: Operator.Core.TaskSup},
      {DynamicSupervisor, name: Operator.Core.LoopSup, strategy: :one_for_one},
      Operator.Core.Current,
      # After Current, which they watch for loops (they re-watch if it restarts).
      Operator.Core.KeepAlive,
      Operator.Core.Voice
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec default_model() :: String.t()
  def default_model, do: Application.get_env(:operator, :default_model, @default_model)

  @spec max_tokens() :: pos_integer()
  def max_tokens, do: Application.get_env(:operator, :max_tokens, 4096)

  @doc "The loop of the session on screen (resuming the latest, or a new one)."
  @spec current() :: pid()
  defdelegate current(), to: Operator.Core.Current

  @doc "Starts a fresh session (same model as the current one) and makes it current."
  @spec new_session() :: pid()
  defdelegate new_session(), to: Operator.Core.Current

  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are Operator, a coding agent that runs entirely on the user's phone (Elixir on the \
    phone's own BEAM). Be brief: the screen is small. Use tools when they help; never invent \
    tool results.

    Write GitHub-flavoured Markdown: headings, **strong**, *emphasis*, `code`, lists, links, \
    > quotes, short tables, ``` fenced code with a language ```. It is shown in a narrow \
    monospace terminal, so keep lines and tables short. Put anything the user is likely to copy \
    (commands, values, URLs, IDs, snippets) in a fenced code block: each block gets a Copy button.

    """ <> Dyn.agent_guide()
  end
end

defmodule Operator.Core.Current do
  @moduledoc """
  Which session's loop the app is showing. At start it resumes the most
  recently written session (or prepares a new one); if that loop dies, the
  next `current/0` reopens the session from its file.

  Background observers (`Operator.Core.KeepAlive`, `Operator.Core.Voice`)
  `watch/1` it: each loop it starts (or has, at the time of the call) gets
  the watcher subscribed to its events before anyone can prompt it, and the
  watcher is sent `{:operator_core_loop, loop_pid, session_id}`.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:dir` (sessions),
  `:loop_sup` (the DynamicSupervisor loops run under), `:loop_opts`.
  """
  use GenServer

  alias Operator.Core.Loop
  alias Operator.Core.Session

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec current(GenServer.server()) :: pid()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @spec new_session(GenServer.server()) :: pid()
  def new_session(server \\ __MODULE__), do: GenServer.call(server, :new_session)

  @doc "Subscribes the caller to the current loop and every later one (see the moduledoc)."
  @spec watch(GenServer.server()) :: :ok
  def watch(server \\ __MODULE__), do: GenServer.call(server, {:watch, self()})

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &Session.dir/0)

    {:ok,
     %{
       dir: dir,
       path: Session.latest(dir),
       pid: nil,
       ref: nil,
       session_id: nil,
       watchers: %{},
       loop_sup: Keyword.get(opts, :loop_sup, Operator.Core.LoopSup),
       loop_opts: Keyword.get(opts, :loop_opts, [])
     }}
  end

  @impl true
  def handle_call(:current, _from, %{pid: pid} = s) when is_pid(pid), do: {:reply, pid, s}

  def handle_call(:current, _from, s) do
    s = start(s, open_or_new(s))
    {:reply, s.pid, s}
  end

  def handle_call(:new_session, _from, s) do
    model = if s.pid, do: Loop.snapshot(s.pid).model, else: Operator.Core.default_model()
    if s.pid, do: stop_loop(s)

    s =
      start(%{s | pid: nil, ref: nil}, {Session.new(s.dir, model, Operator.Paths.data_dir()), []})

    {:reply, s.pid, s}
  end

  def handle_call({:watch, pid}, _from, s) do
    watchers =
      if Map.has_key?(s.watchers, pid),
        do: s.watchers,
        else: Map.put(s.watchers, pid, Process.monitor(pid))

    if s.pid, do: announce(s.pid, s.session_id, [pid])
    {:reply, :ok, %{s | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = s) do
    Logger.warning("[core] session loop exited: #{inspect(reason)}")
    {:noreply, %{s | pid: nil, ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case s.watchers do
      %{^pid => ^ref} -> {:noreply, %{s | watchers: Map.delete(s.watchers, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp open_or_new(%{path: path} = s) when is_binary(path) do
    case Session.open(path, Operator.Core.default_model()) do
      {:ok, session, entries} ->
        {session, entries}

      {:error, reason} ->
        Logger.warning(
          "[core] could not resume #{path}: #{inspect(reason)}; starting a new session"
        )

        open_or_new(%{s | path: nil})
    end
  end

  defp open_or_new(s),
    do: {Session.new(s.dir, Operator.Core.default_model(), Operator.Paths.data_dir()), []}

  # Real loops get the daily cost cap, kept next to the tools' data dir.
  defp start(s, {session, entries}) do
    budget = Keyword.get_lazy(s.loop_opts, :data_dir, &Operator.Paths.data_dir/0)

    opts =
      Keyword.merge(
        [
          session: session,
          entries: entries,
          max_tokens: Operator.Core.max_tokens(),
          budget: budget
        ],
        s.loop_opts
      )

    {:ok, pid} = DynamicSupervisor.start_child(s.loop_sup, {Loop, opts})
    announce(pid, session.id, Map.keys(s.watchers))

    %{s | pid: pid, ref: Process.monitor(pid), path: session.path, session_id: session.id}
  end

  # A watcher monitors the loop it is told about, so one that died before its
  # `:DOWN` reached us is cleaned up on the watcher's side.
  defp announce(loop, session_id, watchers) do
    for w <- watchers do
      try do
        Loop.subscribe(loop, w)
      catch
        :exit, _ -> :ok
      end

      send(w, {:operator_core_loop, loop, session_id})
    end
  end

  defp stop_loop(s) do
    Process.demonitor(s.ref, [:flush])
    DynamicSupervisor.terminate_child(s.loop_sup, s.pid)
  end
end
