defmodule Operator.Core.Loop do
  @moduledoc """
  The agent loop for one session: a GenServer with pi's lifecycle
  (`pi-agent-core/src/agent-loop.ts`; events in `Operator.Core.Events`).

  A run starts with `prompt/2` (or `steer/2` / `follow_up/2` while idle) and
  repeats turns: one model call (streamed), then the reply's tool calls in
  parallel, until the model stops calling tools and nothing is queued.

    * `steer/2` while running queues a user message injected at the next
      step boundary: after the current tool batch, before the next model
      call (or, if the model just stopped, as one more turn).
    * `follow_up/2` while running runs after the agent would stop.
    * `stop/1` kills the in-flight model call and skips tools not yet
      started; started tools finish. The run ends with a notice entry.

  The slow parts never run in this process: the model call runs in a
  monitored worker, each tool in a task under `:task_supervisor`, so the
  loop always answers steer / stop. Guards: `:max_iterations` model calls
  per run (12), explicit `:max_tokens` (4096), up to `:max_retries` (2)
  retries with exponential backoff on 429 / 5xx / transport errors, and
  with `:budget` (a data dir) the per-day cost cap (`Operator.Core.Budget`):
  checked before each model call, each reply's cost recorded.

  Everything is persisted to the session as it happens
  (`Operator.Core.Session`, omp/pi's JSONL).
  """
  use GenServer, restart: :temporary

  alias Operator.Core.Budget
  alias Operator.Core.Events
  alias Operator.Core.LLM
  alias Operator.Core.Session
  alias Operator.Core.Tool
  alias Operator.Core.ToolRegistry
  alias Operator.Core.ToolRunner

  require Logger

  @defaults [
    max_iterations: 12,
    max_tokens: 4096,
    max_retries: 2,
    retry_base_ms: 1_000,
    max_tool_concurrency: 4,
    task_supervisor: Operator.Core.TaskSup,
    tools: :registry,
    before_tool_call: &ToolRunner.allow_all/2,
    llm: {LLM.ReqLLM, []}
  ]

  # ── API ──

  @doc """
  Options: `:session` and `:entries` (from `Session.new/3` or
  `Session.open/2`), `:system_prompt`, `:data_dir` (given to tools),
  `:llm` (`{module, opts}`), `:tools` (`:registry` or a list of tool
  modules), `:before_tool_call` (`fn call, ctx -> :allow | {:block, reason}
  end`), `:task_supervisor`, `:budget` (the data dir holding the cost
  ledger and cap; nil means no cap), and the guards above.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Starts a run. `{:error, :running}` if one is in progress (use `steer/2`)."
  @spec prompt(GenServer.server(), String.t()) :: :ok | {:error, :running}
  def prompt(loop, text), do: GenServer.call(loop, {:prompt, text})

  @doc "Injects `text` at the next step boundary; starts a run if idle."
  @spec steer(GenServer.server(), String.t()) :: :ok
  def steer(loop, text), do: GenServer.call(loop, {:steer, text})

  @doc "Runs `text` once the agent would otherwise stop; starts a run if idle."
  @spec follow_up(GenServer.server(), String.t()) :: :ok
  def follow_up(loop, text), do: GenServer.call(loop, {:follow_up, text})

  @doc "Aborts the model call and unstarted tools; no-op when idle."
  @spec stop(GenServer.server()) :: :ok
  def stop(loop), do: GenServer.call(loop, :stop)

  @doc """
  Sends `pid` (the caller by default) `{:operator_core, session_id, event}`
  for every event, until it exits or unsubscribes.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(loop, pid \\ self()), do: GenServer.call(loop, {:subscribe, pid})

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(loop), do: GenServer.call(loop, {:unsubscribe, self()})

  @doc "Switches the model (a req_llm spec) for later calls; idle only."
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, :running}
  def set_model(loop, model), do: GenServer.call(loop, {:set_model, model})

  @doc """
  `%{session_id, path, title, model, status, entries, totals, streaming,
  queue}`: what a screen needs to draw the session from scratch.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(loop), do: GenServer.call(loop, :snapshot)

  @doc "The req_llm messages the next model call would send (no system prompt)."
  @spec context(GenServer.server()) :: [ReqLLM.Message.t()]
  def context(loop), do: GenServer.call(loop, :context)

  # ── GenServer ──

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      session: Keyword.fetch!(opts, :session),
      entries_rev: opts |> Keyword.get(:entries, []) |> Enum.reverse(),
      opts: Map.new(Keyword.drop(opts, [:session, :entries, :name])),
      subscribers: %{},
      status: :idle,
      steering: [],
      follow_up: [],
      run: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, text}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [Session.user(text)])}

  def handle_call({:prompt, _text}, _from, s), do: {:reply, {:error, :running}, s}

  def handle_call({:steer, text}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [Session.user(text)])}

  def handle_call({:steer, text}, _from, s),
    do: {:reply, :ok, queued(%{s | steering: s.steering ++ [text]})}

  def handle_call({:follow_up, text}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [Session.user(text)])}

  def handle_call({:follow_up, text}, _from, s),
    do: {:reply, :ok, queued(%{s | follow_up: s.follow_up ++ [text]})}

  def handle_call(:stop, _from, s), do: {:reply, :ok, do_stop(s)}

  def handle_call({:subscribe, pid}, _from, s) do
    subs =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{s | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, s) do
    {ref, subs} = Map.pop(s.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{s | subscribers: subs}}
  end

  def handle_call({:set_model, model}, _from, %{status: :idle} = s) do
    {s, _} = persist(s, Session.model_change(model))
    emit(s, %{type: :model_change, model: model})
    {:reply, :ok, s}
  end

  def handle_call({:set_model, _model}, _from, s), do: {:reply, {:error, :running}, s}

  def handle_call(:snapshot, _from, s) do
    entries = Enum.reverse(s.entries_rev)

    snapshot = %{
      session_id: s.session.id,
      path: s.session.path,
      title: s.session.title,
      model: s.session.model,
      status: s.status,
      entries: entries,
      totals: Session.totals(entries),
      streaming: s.run && s.run.stream && IO.iodata_to_binary(s.run.stream.text),
      queue: %{steering: s.steering, follow_up: s.follow_up}
    }

    {:reply, snapshot, s}
  end

  def handle_call(:context, _from, s),
    do: {:reply, Session.context(Enum.reverse(s.entries_rev)), s}

  # model stream worker
  @impl true
  def handle_info({:llm_event, pid, {kind, delta}}, %{run: %{stream: %{pid: pid} = st}} = s)
      when kind in [:text, :thinking] and is_binary(delta) do
    st = Map.update!(st, kind, &[&1, delta])
    emit(s, %{type: :message_update, kind: kind, delta: delta})
    {:noreply, put_run(s, stream: st)}
  end

  def handle_info({:llm_done, pid, result}, %{run: %{stream: %{pid: pid, ref: ref}}} = s) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, reply} -> {:noreply, handle_reply(s, reply)}
      {:error, error} -> {:noreply, handle_error(s, error)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{stream: %{ref: ref}}} = s),
    do:
      {:noreply,
       handle_error(s, {:other, "model call crashed: #{Exception.format_exit(reason)}"})}

  def handle_info(:retry_attempt, %{run: %{phase: :backoff}} = s),
    do: {:noreply, start_attempt(put_run(s, retry_timer: nil))}

  # tool tasks
  def handle_info({:tool_running, pid}, %{run: %{batch: %{running: running}}} = s) do
    case Enum.find(running, fn {_ref, r} -> r.pid == pid end) do
      {ref, r} ->
        timer = Process.send_after(self(), {:tool_timeout, ref}, Tool.timeout_ms(r.module))
        {:noreply, update_batch(s, &put_in(&1, [:running, ref, :timer], timer))}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({ref, result}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, tool_done(s, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref),
      do: {:noreply, tool_done(s, ref, {:error, ToolRunner.crash_text(reason)})}

  def handle_info({:tool_timeout, ref}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref) do
    %{pid: pid, module: module} = running[ref]
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, tool_done(s, ref, {:error, ToolRunner.timeout_text(module)})}
  end

  # subscribers
  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  # late messages from a killed stream worker or a finished batch
  def handle_info(_message, s), do: {:noreply, s}

  # ── run lifecycle ──

  defp start_run(s, inputs) do
    s = %{
      s
      | status: :running,
        run: %{iteration: 0, turn: 0, phase: nil, stopping: false, attempt: 1, stream: nil}
    }

    emit(s, %{type: :agent_start})
    begin_turn(s, inputs)
  end

  defp begin_turn(%{run: %{iteration: n}} = s, inputs) when n >= s.opts.max_iterations do
    dropped = for %{"message" => m} <- inputs, do: Session.text(m["content"])

    text =
      "Stopped after #{n} model calls in one run (max_iterations)." <>
        if(dropped == [], do: "", else: " Not sent: " <> Enum.join(dropped, " / "))

    s |> notice(:notice, text) |> finish(:max_iterations)
  end

  defp begin_turn(s, inputs) do
    run = s.run

    s =
      put_run(s,
        turn: run.turn + 1,
        iteration: run.iteration + 1,
        attempt: 1,
        batch: nil,
        assistant: nil
      )

    emit(s, %{type: :turn_start, turn: s.run.turn})

    s =
      Enum.reduce(inputs, s, fn input, acc ->
        {acc, entry} = persist(acc, input)
        emit(acc, %{type: :message_start, entry: entry})
        emit(acc, %{type: :message_end, entry: entry})
        acc
      end)

    case budget(s) do
      :ok ->
        start_attempt(s)

      {:over, spent, cap} ->
        text =
          "Daily cost cap reached: $#{dollars(spent)} of $#{dollars(cap)} spent today. " <>
            "No more model calls until tomorrow, or until the cap is raised."

        s |> notice(:notice, text) |> finish(:cost_cap)
    end
  end

  defp budget(%{opts: %{budget: dir}}) when is_binary(dir), do: Budget.check(dir)
  defp budget(_s), do: :ok

  defp record_cost(%{opts: %{budget: dir}}, entry) when is_binary(dir),
    do: Budget.record(dir, get_in(entry, ["message", "usage", "cost", "total"]) || 0)

  defp record_cost(_s, _entry), do: :ok

  defp dollars(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp start_attempt(s) do
    {mod, llm_opts} = s.opts.llm
    loop = self()
    request = request(s)

    {pid, ref} =
      spawn_monitor(fn ->
        me = self()
        result = mod.stream(request, llm_opts, &send(loop, {:llm_event, me, &1}))
        send(loop, {:llm_done, me, result})
      end)

    emit(s, %{
      type: :message_start,
      entry: %{"type" => "message", "message" => %{"role" => "assistant", "content" => []}}
    })

    put_run(s, phase: :streaming, stream: %{pid: pid, ref: ref, text: [], thinking: []})
  end

  defp request(s) do
    %{
      model: s.session.model,
      system_prompt: s.opts[:system_prompt] || Operator.Core.system_prompt(),
      messages: Session.context(Enum.reverse(s.entries_rev)),
      tools: s |> tools() |> Map.values() |> Enum.map(&Tool.to_req_llm/1),
      max_tokens: s.opts.max_tokens
    }
  end

  defp tools(%{opts: %{tools: :registry}}),
    do: Map.new(ToolRegistry.list(), &{&1.name(), &1})

  defp tools(%{opts: %{tools: modules}}), do: Map.new(modules, &{&1.name(), &1})

  defp handle_reply(s, reply) do
    calls = reply.tool_calls || []

    stop_reason =
      cond do
        calls != [] -> "toolUse"
        reply[:finish_reason] == :length -> "length"
        true -> "stop"
      end

    reply = Map.merge(reply, %{tool_calls: calls, stop_reason: stop_reason})
    {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
    record_cost(s, entry)
    emit(s, %{type: :message_end, entry: entry})

    if calls == [], do: end_turn(s, entry, []), else: start_batch(s, entry, calls)
  end

  defp handle_error(s, error) do
    %{attempt: attempt, stream: stream} = s.run

    if LLM.retryable?(error) and attempt <= s.opts.max_retries do
      delay = s.opts.retry_base_ms * Integer.pow(2, attempt - 1)
      emit(s, %{type: :retry, attempt: attempt, delay_ms: delay, error: LLM.describe(error)})
      timer = Process.send_after(self(), :retry_attempt, delay)
      put_run(s, phase: :backoff, attempt: attempt + 1, stream: nil, retry_timer: timer)
    else
      message = LLM.describe(error)
      Logger.warning("[loop] model call failed: #{message}")

      reply = %{
        text: IO.iodata_to_binary(stream.text),
        thinking: IO.iodata_to_binary(stream.thinking),
        stop_reason: "error",
        error: message
      }

      {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
      emit(s, %{type: :message_end, entry: entry})

      emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: [], error: message})

      finish(s, :error)
    end
  end

  defp end_turn(s, entry, results) do
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: results, error: nil})
    has_calls = Session.tool_calls(entry["message"]) != []

    cond do
      s.run.stopping -> stopped(s)
      has_calls or s.steering != [] -> drain(s, :steering)
      s.follow_up != [] -> drain(s, :follow_up)
      true -> finish(s, :done)
    end
  end

  defp drain(s, :steering) do
    inputs = for text <- s.steering, do: Session.user(text, steering: true)
    s = %{s | steering: []}
    if inputs != [], do: queued(s)
    begin_turn(s, inputs)
  end

  defp drain(s, :follow_up) do
    inputs = for text <- s.follow_up, do: Session.user(text)
    s |> Map.put(:follow_up, []) |> queued() |> begin_turn(inputs)
  end

  defp finish(s, reason) do
    had_queue = s.steering != [] or s.follow_up != []
    s = %{s | status: :idle, run: nil, steering: [], follow_up: []}
    if had_queue, do: emit(s, %{type: :queue, steering: [], follow_up: []})
    emit(s, %{type: :agent_end, reason: reason})
    s
  end

  # ── stop ──

  defp do_stop(%{status: :idle} = s), do: s
  defp do_stop(%{run: %{stopping: true}} = s), do: s

  defp do_stop(%{run: %{phase: :streaming, stream: st}} = s) do
    Process.demonitor(st.ref, [:flush])
    Process.exit(st.pid, :kill)
    aborted_turn(s, IO.iodata_to_binary(st.text), IO.iodata_to_binary(st.thinking))
  end

  defp do_stop(%{run: %{phase: :backoff, retry_timer: timer}} = s) do
    if timer, do: Process.cancel_timer(timer)
    aborted_turn(s, "", "")
  end

  defp do_stop(%{run: %{phase: :tools, batch: batch}} = s) do
    skipped = Map.new(batch.queue, &{&1, {ToolRunner.skipped_text(), true}})

    s =
      update_batch(
        put_run(s, stopping: true),
        &%{&1 | queue: [], results: Map.merge(&1.results, skipped)}
      )

    maybe_complete(s)
  end

  defp aborted_turn(s, text, thinking) do
    reply = %{text: text, thinking: thinking, stop_reason: "aborted"}
    {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
    emit(s, %{type: :message_end, entry: entry})
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: [], error: nil})
    stopped(s)
  end

  defp stopped(s) do
    dropped = s.steering ++ s.follow_up

    text =
      "Stopped by the user." <>
        if(dropped == [], do: "", else: " Not sent: " <> Enum.join(dropped, " / "))

    s |> notice(:notice, text) |> finish(:stopped)
  end

  # ── tool batch ──

  defp start_batch(s, entry, calls) do
    available = tools(s)
    indexed = calls |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)

    {queue, results} =
      Enum.reduce(0..(length(calls) - 1), {[], %{}}, fn i, {queue, results} ->
        name = indexed[i]["name"]

        if Map.has_key?(available, name) do
          {[i | queue], results}
        else
          known = available |> Map.keys() |> Enum.sort() |> Enum.join(", ")

          {queue,
           Map.put(results, i, {"Tool not found: #{name}. Available tools: #{known}", true})}
        end
      end)

    batch = %{
      calls: indexed,
      tools: available,
      queue: Enum.reverse(queue),
      running: %{},
      results: results
    }

    s
    |> put_run(phase: :tools, assistant: entry, batch: batch)
    |> pump()
    |> maybe_complete()
  end

  defp pump(%{run: %{batch: %{queue: [i | rest], running: running} = batch}} = s)
       when map_size(running) < s.opts.max_tool_concurrency do
    call = batch.calls[i]
    module = batch.tools[call["name"]]

    ctx = %{
      session_id: s.session.id,
      call_id: call["id"],
      data_dir: s.opts[:data_dir] || Operator.Paths.data_dir()
    }

    task =
      ToolRunner.start(s.opts.task_supervisor, self(), module, call, s.opts.before_tool_call, ctx)

    emit(s, %{
      type: :tool_execution_start,
      id: call["id"],
      name: call["name"],
      arguments: call["arguments"]
    })

    run = %{idx: i, pid: task.pid, module: module, timer: nil}
    s |> update_batch(&%{&1 | queue: rest, running: Map.put(&1.running, task.ref, run)}) |> pump()
  end

  defp pump(s), do: s

  defp tool_done(s, ref, result) do
    %{idx: i, timer: timer} = s.run.batch.running[ref]
    if timer, do: Process.cancel_timer(timer)
    call = s.run.batch.calls[i]

    {text, is_error} =
      case result do
        {:ok, text} -> {text, false}
        {:error, text} -> {text, true}
      end

    emit(s, %{
      type: :tool_execution_end,
      id: call["id"],
      name: call["name"],
      text: text,
      is_error: is_error
    })

    s
    |> update_batch(
      &%{
        &1
        | running: Map.delete(&1.running, ref),
          results: Map.put(&1.results, i, {text, is_error})
      }
    )
    |> then(&if(&1.run.stopping, do: &1, else: pump(&1)))
    |> maybe_complete()
  end

  defp maybe_complete(%{run: %{batch: %{queue: [], running: running} = batch}} = s)
       when map_size(running) == 0 do
    {s, entries} =
      Enum.reduce(0..(map_size(batch.calls) - 1), {s, []}, fn i, {acc, entries} ->
        call = batch.calls[i]
        {text, is_error} = batch.results[i]
        {acc, entry} = persist(acc, Session.tool_result(call["id"], call["name"], text, is_error))
        emit(acc, %{type: :message_start, entry: entry})
        emit(acc, %{type: :message_end, entry: entry})
        {acc, [entry | entries]}
      end)

    end_turn(put_run(s, batch: nil), s.run.assistant, Enum.reverse(entries))
  end

  defp maybe_complete(s), do: s

  # ── helpers ──

  defp notice(s, kind, text) do
    {s, entry} = persist(s, Session.custom(kind, text))
    emit(s, %{type: :message_start, entry: entry})
    emit(s, %{type: :message_end, entry: entry})
    s
  end

  defp queued(s) do
    emit(s, %{type: :queue, steering: s.steering, follow_up: s.follow_up})
    s
  end

  defp persist(s, entry) do
    {session, written} = Session.append(s.session, entry)
    {%{s | session: session, entries_rev: [written | s.entries_rev]}, written}
  end

  defp put_run(s, kv), do: %{s | run: Enum.into(kv, s.run)}

  defp update_batch(s, fun), do: put_run(s, batch: fun.(s.run.batch))

  defp emit(s, event), do: Events.broadcast(Map.keys(s.subscribers), s.session.id, event)
end
