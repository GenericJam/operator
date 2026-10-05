defmodule Operator.Core do
  @moduledoc """
  The fixed core (docs/DESIGN.md §1): the agent loop, sessions, core tools.
  Started by `Operator.Boot`; supervises the approval store and
  `Operator.Core.Dyn.Keeper` (which Dyn generation runs; `Operator.Boot`
  then loads it), `Operator.Core.Front` (the front: which Dyn screen shows
  and the process it runs in), the tool registry,
  the task supervisor tools run under, the loops, `Operator.Core.Current`
  (which session the app is showing; the latest one is resumed at boot),
  `Operator.Handoff.Inbox` (the parts of a handoff scanned so far), and
  the observers of its runs: `Operator.Core.KeepAlive` (keeps the app
  running in the background during a run) and `Operator.Core.Voice`
  (reads updates aloud).

  Config (`config :operator, ...`): `:default_model` (a req_llm spec,
  default `#{inspect("anthropic:claude-haiku-4-5")}`), `:max_tokens` (4096).
  """
  use Supervisor

  alias Operator.Core.Current
  alias Operator.Core.Docs
  alias Operator.Core.Dyn
  alias Operator.Core.DynTheme
  alias Operator.Core.Front

  @default_model "anthropic:claude-haiku-4-5"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Operator.Core.Dyn.Approval.Biometric,
      Operator.Core.Dyn.Keeper,
      # After the Keeper, whose events it follows.
      DynTheme,
      Operator.Core.Front,
      Operator.Core.ToolRegistry,
      {Task.Supervisor, name: Operator.Core.TaskSup},
      {DynamicSupervisor, name: Operator.Core.LoopSup, strategy: :one_for_one},
      Operator.Core.Current,
      Operator.Handoff.Inbox,
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

  @doc """
  Starts a fresh session that opens with `entry` and makes it current
  (`Operator.Core.Current.new_session_with/3`).
  """
  @spec new_session_with(Operator.Core.Session.entry(), keyword()) :: pid()
  def new_session_with(entry, opts \\ []), do: Current.new_session_with(entry, opts)

  @doc "Opens a session file (from omp, say) and makes it current (`Operator.Core.Current.open/2`)."
  @spec open_session(Path.t()) :: {:ok, pid()} | {:error, term()}
  def open_session(path), do: Current.open(path)

  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are Operator, a coding agent that runs entirely on the user's phone. Be brief: the \
    screen is small. Use tools when they help; never invent tool results.

    Write GitHub-flavoured Markdown: headings, **strong**, *emphasis*, `code`, lists, links, \
    > quotes, short tables, ``` fenced code with a language ```. It is shown in a narrow \
    monospace terminal, so keep lines and tables short. Put anything the user is likely to copy \
    (commands, values, URLs, IDs, snippets) in a fenced code block: each block gets a Copy button.

    ## This environment

    - You run inside Operator, an app (Android and iOS) written in Elixir with mob: the \
    phone's own BEAM, one scheduler, so long computations slow everything, the UI included.
    - No shell, Mix, Hex or package installs. You can't add dependencies, plugins, native \
    code or Android permissions: those need a native build on the user's Mac. Say so rather \
    than work around it. The internet is reachable (`http_get`; `Req` in your code).
    - Two layers. The Core (this loop, sessions, sign-in, your core tools, approval, the \
    rescue screen) ships in the app; you can't change it, the Mac updates it by cable or over \
    the air on the home network. The Dyn layer is yours: screens, tools, the theme. A Dyn \
    change compiles here (20-40 s), takes the user's screen-lock approval and runs on \
    probation, reverting itself if it crashes.
    - The app has a front (the screens you build with the user) and a back (this terminal); \
    the logo in the front's upper left corner goes to the terminal, `[frontend]` in the \
    terminal's top bar goes to the front. The terminal's `[menu]` is where the user signs \
    in, picks the model, starts or resumes a session and opens diagnostics; the chat has no \
    commands, so point the user there for those.
    - Phone tools: `camera_snap` (you take a photo yourself, no one touches the phone, and \
    see it), `camera_photo` (the user takes it), `photos_recent` (look at the newest photos), \
    `pick_photos` (the user picks; you see them, with when and where they were taken), \
    `sensors` (motion, compass, barometer, light, proximity, steps, battery, every sensor the \
    phone has), `location`, `clipboard`, `notify`, `http_get`, `notes` (the user's notes \
    file). Permissions are asked at first use, by your tools or a screen; the user may \
    refuse, or miss the prompt: say what to allow and try again. A long tool output is cut; \
    `read_artifact` reads the rest.
    - Files: `file_list`, `file_read` (text, or a picture you see), `file_write`, \
    `file_copy`, `file_delete`, `file_pick` (the user picks a document from any app). They \
    work in your workspace and, on Android, the phone's shared storage (Download, DCIM, \
    Documents, ...: the user switches on All files access the first time); `file_list` with \
    no path shows the places. To hand the user a file on Android, copy it to Download; on \
    iOS files stay in the workspace, private to the app. Sessions, settings and Dyn \
    generations stay private.
    - Dyn code has files too, through `Operator.Core.Files` (same places); sensors \
    (`Mob.Motion` for accelerometer, gyro and compass heading; `MobSensors` for the rest); \
    tensors (`Nx`, on the Eigen CPU backend); models on the GPU/NPU (`Operator.Core.Tflite`: \
    NNAPI on Android, Core ML on iOS, a bundled MobileNet); and the GPU itself (`<GpuView>`: \
    a fragment shader, GLSL ES 3.0 on Android, Metal on iOS, \
    `shader: %{android: glsl, ios: msl}`). Small state goes in `Mob.State`.

    """ <>
      Dyn.agent_guide() <>
      "\n" <>
      DynTheme.agent_guide() <>
      "\n" <>
      Docs.agent_guide() <>
      "\n" <> Front.agent_guide() <> "\n" <> Docs.guide_index()
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

  @doc """
  Starts a fresh session (as `new_session/1`) that opens with `entry`,
  written before its loop starts: the model sees it with the next prompt,
  and nothing is sent until then. `opts[:title]` titles the session
  (default: from `entry`, as for a first prompt).
  """
  @spec new_session_with(Session.entry(), keyword(), GenServer.server()) :: pid()
  def new_session_with(entry, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:new_session, entry, opts})

  @doc """
  Opens the session file at `path` and makes it current. A file outside
  the sessions dir (one from omp, say) is copied in first, so the phone
  appends to its own copy. A session last run on a model Operator can't
  call (a provider other than `anthropic` / `openai_codex`, or one that
  isn't signed in) continues on the default model.
  """
  @spec open(Path.t(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def open(path, server \\ __MODULE__), do: GenServer.call(server, {:open, path})

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
    {session, s} = replace(s)
    s = start(s, {session, []})
    {:reply, s.pid, s}
  end

  # Read back from the file, so the loop holds what a resume would (the
  # header's model_change included).
  def handle_call({:new_session, entry, opts}, _from, s) do
    {session, s} = replace(s)
    {session, _} = Session.append(%{session | title: opts[:title]}, entry)
    {:ok, session, entries} = Session.open(session.path, session.model)
    s = start(s, {session, entries})
    {:reply, s.pid, s}
  end

  def handle_call({:open, path}, _from, s) do
    with {:ok, path} <- into_dir(path, s.dir),
         {:ok, session, entries} <- Session.open(path, Operator.Core.default_model()) do
      session = %{session | model: usable_model(session.model)}

      if s.pid, do: stop_loop(s)
      s = start(%{s | pid: nil, ref: nil}, {session, entries})
      {:reply, {:ok, s.pid}, s}
    else
      {:error, _} = error -> {:reply, error, s}
    end
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
        {%{session | model: usable_model(session.model)}, entries}

      {:error, reason} ->
        Logger.warning(
          "[core] could not resume #{path}: #{inspect(reason)}; starting a new session"
        )

        open_or_new(%{s | path: nil})
    end
  end

  defp open_or_new(s),
    do: {Session.new(s.dir, Operator.Core.default_model(), Operator.Paths.data_dir()), []}

  defp usable_model(model) do
    case Operator.Auth.provider_for_model(model) do
      {:ok, provider} ->
        if Operator.Auth.signed_in?(provider), do: model, else: Operator.Core.default_model()

      :error ->
        Operator.Core.default_model()
    end
  end

  defp into_dir(path, dir) do
    if Path.dirname(Path.expand(path)) == Path.expand(dir) do
      {:ok, path}
    else
      dest = Path.join(dir, Path.basename(path))

      with :ok <- File.mkdir_p(dir), :ok <- File.cp(path, dest), do: {:ok, dest}
    end
  end

  # A new, unwritten session on the shown loop's model; that loop stopped.
  defp replace(s) do
    model = if s.pid, do: Loop.snapshot(s.pid).model, else: Operator.Core.default_model()
    if s.pid, do: stop_loop(s)
    {Session.new(s.dir, model, Operator.Paths.data_dir()), %{s | pid: nil, ref: nil}}
  end

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
