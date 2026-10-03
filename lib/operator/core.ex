defmodule Operator.Core do
  @moduledoc """
  The fixed core (docs/DESIGN.md §1): the agent loop, sessions, core tools.
  Started by `Operator.Boot`; supervises the tool registry, the task
  supervisor tools run under, the loops, and `Operator.Core.Current`
  (which session the app is showing; the latest one is resumed at boot).

  Config (`config :operator, ...`): `:default_model` (a req_llm spec,
  default `#{inspect("openrouter:anthropic/claude-haiku-4.5")}`), `:max_tokens` (4096).
  """
  use Supervisor

  @default_model "openrouter:anthropic/claude-haiku-4.5"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Operator.Core.ToolRegistry,
      {Task.Supervisor, name: Operator.Core.TaskSup},
      {DynamicSupervisor, name: Operator.Core.LoopSup, strategy: :one_for_one},
      Operator.Core.Current
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
    """
  end
end

defmodule Operator.Core.Current do
  @moduledoc """
  Which session's loop the app is showing. At start it resumes the most
  recently written session (or prepares a new one); if that loop dies, the
  next `current/0` reopens the session from its file.
  """
  use GenServer

  alias Operator.Core.Loop
  alias Operator.Core.Session

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec current() :: pid()
  def current, do: GenServer.call(__MODULE__, :current)

  @spec new_session() :: pid()
  def new_session, do: GenServer.call(__MODULE__, :new_session)

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &Session.dir/0)

    {:ok,
     %{
       dir: dir,
       path: Session.latest(dir),
       pid: nil,
       ref: nil,
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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = s) do
    Logger.warning("[core] session loop exited: #{inspect(reason)}")
    {:noreply, %{s | pid: nil, ref: nil}}
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

  defp start(s, {session, entries}) do
    opts =
      [session: session, entries: entries, max_tokens: Operator.Core.max_tokens()] ++ s.loop_opts

    {:ok, pid} = DynamicSupervisor.start_child(Operator.Core.LoopSup, {Loop, opts})
    %{s | pid: pid, ref: Process.monitor(pid), path: session.path}
  end

  defp stop_loop(s) do
    Process.demonitor(s.ref, [:flush])
    DynamicSupervisor.terminate_child(Operator.Core.LoopSup, s.pid)
  end
end
