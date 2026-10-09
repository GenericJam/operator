defmodule Operator.Core.EvalKernel do
  @moduledoc """
  What the `eval` tool (`Operator.Core.Tools.Eval`) runs on: the
  evaluation itself, and the store that keeps each session's bindings so a
  variable bound in one call is there in the next, like an iex prompt.

  Every evaluation runs in a fresh process, never in the loop, the tool's
  task or this store: it prints into a bounded capture
  (`Operator.Core.EvalKernel.Capture`), and is killed at its timeout, when
  the user stops the run, or past a heap cap (off-heap binaries count).
  A small watcher kills it (and the capture) if the caller dies first, so
  when the loop kills a tool call that overran, the evaluation goes with
  it; nothing is linked to the caller, so a crash in the evaluated code
  can't take the tool's task down. The result comes back as text,
  inspected and truncated in the evaluation process, so the timeout and
  heap cap cover a huge `inspect` too.

  The store is in memory on purpose: a binding can hold pids, refs and
  closures that mean nothing after a restart, so a fresh launch is a clean
  slate. It is bounded by count, age and size: at most eight sessions (the
  least recently used is dropped first), a session untouched for 30
  minutes is dropped, and a call whose bindings come to more than 4 MB
  (binaries included) doesn't keep them. Aliases, requires and imports
  carry over too (the evaluation environment is kept with the bindings).
  The loop runs a turn's tool calls side by side, so a session's
  evaluations take a lock (`locked/2`) and run one after the other; each
  sees what the one before it bound.

  The text that comes back has the current sign-in tokens (and the
  cluster cookie) replaced by `[redacted sign-in token]`, so code the
  model was talked into running can't copy them into the session file.
  That is a seatbelt, not a sandbox: the evaluation itself can still read
  them, send them anywhere, or print them in pieces.
  """
  use GenServer

  alias Operator.Core.EvalKernel.Capture
  alias Operator.Core.ToolRegistry

  @max_sessions 8
  @idle_ms 30 * 60_000
  @sweep_ms 5 * 60_000

  # What comes back to the model: the inspected value and the printed
  # output, each capped; the loop spills anything over 16 KiB anyway, so
  # together they stay under it.
  @max_value_bytes 8_000
  @max_stdout_bytes 6_000
  # A runaway allocation kills the evaluation, not the app.
  @max_heap_bytes 50_000_000
  # Bindings kept per session between calls (eight sessions at most).
  @max_binding_bytes 4_000_000
  @redacted "[redacted sign-in token]"
  # Shorter strings aren't secrets worth hiding, and would hit ordinary text.
  @min_secret_bytes 16
  # Where `Operator.Cluster` keeps the cluster's cookie.
  @cluster_cookie_account "cluster_cookie"
  @max_frames 12

  # The evaluator's own frames, not the agent's (the evaluated code's own
  # lines show as `:elixir_compiler` frames in the file "eval").
  @internal [
    :elixir,
    :elixir_compiler,
    :elixir_dispatch,
    :erl_eval,
    Code,
    Module.ParallelChecker,
    __MODULE__
  ]

  @type session :: %{binding: keyword(), env: Macro.Env.t() | nil}
  @type result :: {:ok | :error, String.t(), session() | nil}

  # ── store ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The session's bindings and environment (empty when it has none)."
  @spec get(term()) :: session()
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @doc "Keeps what a successful evaluation left for the session's next call."
  @spec put(term(), session()) :: :ok
  def put(session_id, session), do: GenServer.call(__MODULE__, {:put, session_id, session})

  @doc "Drops the session's bindings; answers how many names it had."
  @spec reset(term()) :: non_neg_integer()
  def reset(session_id), do: GenServer.call(__MODULE__, {:reset, session_id})

  @doc "The sessions that have bindings now (for tests and diagnostics)."
  @spec sessions() :: [term()]
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @doc """
  Runs `fun` holding the session's lock, so its evaluations (get, evaluate,
  put) don't overlap. The lock goes with the process holding it.
  """
  @spec locked(term(), (-> result)) :: result when result: term()
  def locked(session_id, fun),
    do: :global.trans({{__MODULE__, session_id}, self()}, fun, [node()])

  @impl true
  def init(opts) do
    sweep_ms = Keyword.get(opts, :sweep_ms, @sweep_ms)
    Process.send_after(self(), :sweep, sweep_ms)

    {:ok,
     %{
       sessions: %{},
       max: Keyword.get(opts, :max_sessions, @max_sessions),
       idle_ms: Keyword.get(opts, :idle_ms, @idle_ms),
       sweep_ms: sweep_ms
     }}
  end

  @impl true
  def handle_call({:get, id}, _from, s) do
    case s.sessions do
      %{^id => {session, _at}} ->
        {:reply, session, put_in(s.sessions[id], {session, now()})}

      _ ->
        {:reply, %{binding: [], env: nil}, s}
    end
  end

  def handle_call({:put, id, session}, _from, s) do
    sessions = Map.put(s.sessions, id, {session, now()})
    {:reply, :ok, %{s | sessions: evict(sessions, s.max)}}
  end

  def handle_call({:reset, id}, _from, s) do
    n =
      case s.sessions do
        %{^id => {%{binding: b}, _}} -> length(b)
        _ -> 0
      end

    {:reply, n, %{s | sessions: Map.delete(s.sessions, id)}}
  end

  def handle_call(:sessions, _from, s), do: {:reply, Map.keys(s.sessions), s}

  @impl true
  def handle_info(:sweep, s) do
    {now_ms, _} = now()
    cutoff = now_ms - s.idle_ms
    sessions = for {id, {_, {at, _}} = v} <- s.sessions, at >= cutoff, into: %{}, do: {id, v}
    Process.send_after(self(), :sweep, s.sweep_ms)
    {:noreply, %{s | sessions: sessions}}
  end

  defp evict(sessions, max) when map_size(sessions) <= max, do: sessions

  defp evict(sessions, max) do
    {oldest, _} = Enum.min_by(sessions, fn {_, {_, used}} -> used end)
    sessions |> Map.delete(oldest) |> evict(max)
  end

  # When a session was last used: the millisecond (for the idle sweep) and
  # a tick that orders uses within one (for least recently used).
  defp now,
    do: {System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}

  # ── evaluation ──

  @doc """
  Evaluates `code` with `session`'s bindings in a fresh process, with
  `tool` bound to `call_tool/3` under `ctx`. Answers `{:ok, text,
  session}` (what to keep for the next call; nil when there is nothing
  to keep) or `{:error, text, nil}`. Runs in the caller, which waits up to
  `timeout_ms`, or until it gets `{:operator_core_stop, loop}` (the user
  stopped the run). Options (tests): `:max_heap_bytes`,
  `:max_binding_bytes`.
  """
  @spec evaluate(String.t(), session(), map(), pos_integer(), keyword()) :: result()
  def evaluate(code, session, ctx, timeout_ms, opts \\ []) do
    caller = self()
    ref = make_ref()
    {:ok, capture} = GenServer.start(Capture, @max_stdout_bytes)
    binding = Keyword.put(session.binding, :tool, &call_tool(&1, &2, ctx))
    env = session.env || Code.env_for_eval(file: "eval", line: 1)
    heap_bytes = Keyword.get(opts, :max_heap_bytes, @max_heap_bytes)
    binding_bytes = Keyword.get(opts, :max_binding_bytes, @max_binding_bytes)

    {pid, mon} =
      spawn_monitor(fn ->
        Process.group_leader(self(), capture)

        Process.flag(:max_heap_size, %{
          size: div(heap_bytes, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        send(caller, {ref, run(code, binding, env, binding_bytes)})
      end)

    watcher = watch(caller, [pid, capture])

    outcome =
      receive do
        {^ref, outcome} ->
          Process.demonitor(mon, [:flush])
          outcome

        {:DOWN, ^mon, :process, ^pid, reason} ->
          {:error, exit_text(reason, heap_bytes), [], nil}

        {:operator_core_stop, _loop} ->
          kill(pid, mon, ref)
          {:error, "Stopped by the user.", [], nil}
      after
        timeout_ms ->
          kill(pid, mon, ref)
          {:error, "Evaluation timed out after #{timeout_ms} ms and was killed.", [], nil}
      end

    {out, total} = Capture.contents(capture)
    GenServer.stop(capture)
    send(watcher, :done)
    outcome |> assemble(out, total) |> redact()
  end

  defp kill(pid, mon, ref) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^mon, :process, ^pid, _} -> :ok)
    receive do: ({^ref, _} -> :ok), after: (0 -> :ok)
  end

  # Kills `pids` if `caller` dies before it says it is done with them.
  defp watch(caller, pids) do
    spawn(fn ->
      mon = Process.monitor(caller)

      receive do
        :done -> :ok
        {:DOWN, ^mon, :process, _, _} -> Enum.each(pids, &Process.exit(&1, :kill))
      end
    end)
  end

  defp exit_text(:killed, heap_bytes),
    do:
      "The evaluation process was killed (its memory passed " <>
        "#{mb(heap_bytes)} MB, or the code killed it)."

  defp exit_text(reason, _heap_bytes),
    do: "The evaluation process exited: " <> Exception.format_exit(reason)

  defp mb(bytes), do: Float.round(bytes / 1_000_000, 1)

  # In the evaluation process: compile and run, then turn everything the
  # model sees into text here, under the timeout and heap cap.
  defp run(code, binding, env, binding_bytes) do
    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          quoted =
            code
            |> Code.string_to_quoted!(file: "eval", line: 1, columns: true)
            |> resolve_dyn(code)

          {value, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
          {:ok, value, binding, env}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end
      end)

    warnings = for %{severity: :warning} = d <- diagnostics, do: diagnostic(d)
    errors = for %{severity: :error} = d <- diagnostics, do: diagnostic(d)

    case outcome do
      {:ok, value, binding, env} ->
        text = inspect(value, pretty: true, limit: 50, printable_limit: 4_000)
        binding = Keyword.delete(binding, :tool)
        # Binaries included, which `:erts_debug.flat_size/1` leaves out.
        bytes = :erlang.external_size(binding)

        if bytes > binding_bytes do
          note =
            "the bindings came to #{mb(bytes)} MB, over the #{mb(binding_bytes)} MB kept " <>
              "between calls, so this call's were not kept (the previous ones were); " <>
              "bind smaller values"

          {:ok, cap(text, @max_value_bytes), warnings ++ [note], nil}
        else
          {:ok, cap(text, @max_value_bytes), warnings, %{binding: binding, env: env}}
        end

      {:error, kind, reason, stack} ->
        text =
          case {errors, reason} do
            # The diagnostics say what was wrong; the exception only that
            # compiling failed.
            {[_ | _], %CompileError{}} -> Enum.join(errors, "\n")
            _ -> Enum.join(errors ++ [Exception.format(kind, reason, trim(stack))], "\n")
          end

        {:error, text |> String.trim_trailing() |> cap(@max_value_bytes), warnings, nil}
    end
  end

  # Dyn code names its modules `Operator.Dyn.Menu`; they are compiled as
  # `Operator.Dyn.G<n>.Menu` (`Operator.Core.Dyn.Compiler.rewrite/2`). An
  # alias to a module of the running generation, or to a namespace one of
  # them is under (`Operator.Dyn.Showcase.Phone`), points at that
  # generation's; any other is left as written, so a typo still says the
  # module isn't available.
  defp resolve_dyn(quoted, code) do
    if code =~ "Operator.Dyn.", do: rewrite_dyn(quoted, dyn_names()), else: quoted
  end

  defp rewrite_dyn(quoted, names) do
    Macro.prewalk(quoted, fn
      {:__aliases__, _meta, [:Operator, :Dyn | rest]} = node ->
        dyn_alias(node, rest, names)

      {:__aliases__, _meta, [:"Elixir", :Operator, :Dyn | rest]} = node ->
        dyn_alias(node, rest, names)

      other ->
        other
    end)
  end

  defp dyn_alias(node, rest, names) do
    if rest != [] and Enum.all?(rest, &is_atom/1),
      do: Map.get(names, Enum.map_join(rest, ".", &Atom.to_string/1), node),
      else: node
  end

  # The running generation's logical names (and the namespaces above them)
  # to its modules: `"Showcase.Phone" => Operator.Dyn.G43.Showcase.Phone`.
  defp dyn_names do
    for {_key, mod} <- Operator.Core.Dyn.Registry.entries(Operator.Core.Dyn.Keeper),
        ["Operator", "Dyn", "G" <> _ = gen | rest] <- [Module.split(mod)],
        n <- 1..length(rest)//1,
        into: %{} do
      logical = Enum.take(rest, n)
      {Enum.join(logical, "."), Module.concat(["Operator", "Dyn", gen | logical])}
    end
  rescue
    _ -> %{}
  end

  defp diagnostic(%{message: message} = d) do
    case d[:position] do
      {line, col} -> "eval:#{line}:#{col}: #{message}"
      line when is_integer(line) and line > 0 -> "eval:#{line}: #{message}"
      _ -> message
    end
  end

  defp trim(stack) do
    stack
    |> Enum.reject(fn {mod, _, _, loc} -> mod in @internal and loc[:file] != ~c"eval" end)
    |> Enum.take(@max_frames)
  end

  # The text for the model: what was printed and any warnings first, then
  # the value (or the error).
  defp assemble({kind, text, warnings, session}, out, total) do
    out = utf8(out)
    more = total - byte_size(out)
    out = if more > 0, do: out <> "\n... (#{more} more bytes printed, not kept)", else: out

    sections =
      [{"stdout", String.trim_trailing(out)}, {"warnings", Enum.join(warnings, "\n")}]
      |> Enum.reject(fn {_, body} -> body == "" end)
      |> Enum.map(fn {title, body} -> "#{title}:\n#{body}\n" end)

    text =
      case sections do
        [] ->
          text

        _ ->
          IO.iodata_to_binary([
            sections,
            if(kind == :ok, do: "result:\n", else: "error:\n"),
            text
          ])
      end

    {kind, text, session}
  end

  defp cap(text, max) when byte_size(text) <= max, do: text

  defp cap(text, max),
    do: utf8(binary_part(text, 0, max)) <> "\n... (truncated, #{byte_size(text)} bytes in all)"

  # Drops a character cut in half at the end.
  defp utf8(bin) do
    if String.valid?(bin), do: bin, else: utf8(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # ── redaction ──

  defp redact({kind, text, session}) do
    case secrets() do
      [] -> {kind, text, session}
      secrets -> {kind, String.replace(text, secrets, @redacted), session}
    end
  end

  # The secrets to hide, longest first (so one inside another can't leave
  # part of the longer behind). `config :operator, :eval_secrets` replaces
  # where they come from (a 0-arity function; tests).
  defp secrets do
    source = Application.get_env(:operator, :eval_secrets, &live_secrets/0)

    source.()
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_secret_bytes))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  catch
    _, _ -> []
  end

  @doc false
  # The current sign-ins' tokens and the cluster cookie (live and stored).
  @spec live_secrets() :: [String.t()]
  def live_secrets do
    tokens =
      for provider <- Operator.Auth.providers(),
          {:ok, creds} <- [safely(fn -> Operator.Auth.get(provider) end)],
          # Operator.Auth's credential shape (auth.ex): "access" and "refresh".
          key <- ~w(access refresh),
          do: creds[key]

    cookie = if Node.alive?(), do: Atom.to_string(Node.get_cookie())

    stored =
      case safely(fn -> Operator.SecureStore.get(@cluster_cookie_account) end) do
        {:ok, cookie} -> cookie
        _ -> nil
      end

    [cookie, stored | tokens]
  end

  defp safely(fun) do
    fun.()
  catch
    _, _ -> :error
  end

  # ── tool ──

  @doc """
  What `tool.(name, args)` does inside an evaluation: runs the registered
  tool `name` with `args` (atom keys become strings, as the model's JSON
  would have them) under the evaluating call's `ctx`, and answers its
  `{:ok, _} | {:error, _}`. A crash in the tool becomes an error. `eval`
  itself can't be called this way, nor a tool this session withholds from
  the model (`ctx.withheld`).
  """
  @spec call_tool(String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool("eval", _args, _ctx), do: {:error, "eval cannot call eval"}

  def call_tool(name, args, ctx) when is_binary(name) and is_map(args) do
    if name in Map.get(ctx, :withheld, []) do
      {:error, "`#{name}` isn't available in this session"}
    else
      run_tool(name, args, ctx)
    end
  end

  def call_tool(name, args, _ctx),
    do:
      {:error,
       "tool.(name, args) takes a string and a map, got #{inspect(name)}, #{inspect(args, limit: 5)}"}

  defp run_tool(name, args, ctx) do
    case ToolRegistry.lookup(name) do
      {:ok, Operator.Core.Tools.Eval} -> {:error, "eval cannot call eval"}
      {:ok, module} -> module.run(stringify(args), ctx)
      :error -> {:error, "no tool named #{inspect(name)}"}
    end
  catch
    kind, reason ->
      {:error, "Tool crashed: " <> Exception.format_banner(kind, reason, __STACKTRACE__)}
  end

  defp stringify(%{__struct__: _} = struct), do: struct
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k
end
