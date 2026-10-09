defmodule Operator.Core.Tools.Subagent do
  @moduledoc """
  Core tool `task`: omp's subagents on the phone. Each task runs in a
  fresh session of its own (an `Operator.Core.Loop`), all of them at once,
  and the call returns each one's final answer, so the agent can fan out
  independent research (guides, docs, plugin APIs, a review of a proposal)
  without filling its own context with every page read along the way.

  A subagent is configured like its caller's loop (`Operator.Core.Loop.config/1`):
  the same model, LLM, tools, approval gate and daily cost cap, and at most
  `Operator.Core.max_iterations/0` model calls. It is never offered `task`
  (the loop's `:withhold_tools`), so it can't fan out again. Its session is
  written under `<sessions dir>/subagents/`, out of the list the app resumes
  from, and it is never made current: the user's screen stays on the
  caller's session.

  The call waits for every subagent's `agent_end`. Near the tool's own
  timeout, the ones still running are stopped (`Operator.Core.Loop.stop/1`)
  and reported as timed out with what they had written; stopping the
  caller's run (the loop sends running tools `{:operator_core_stop, loop}`)
  or the caller's loop going away does the same. The subagents run outside
  the call's process, started by a guard that ends them before the call
  returns (so none outlives it, though `eval`'s evaluator, a caller that
  lives for the session, does), or once the call's process is gone however
  it went (killed at its timeout included), so none keeps calling the
  model in the background.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Artifacts
  alias Operator.Core.Loop
  alias Operator.Core.Session

  @max_tasks 4
  @timeout_ms 15 * 60_000
  # The report goes out before the loop kills the call at `timeout_ms/0`.
  @deadline_ms @timeout_ms - 15_000

  @impl true
  def name, do: "task"

  @impl true
  def description do
    "Run 1-#{@max_tasks} subagents in parallel, each in a fresh session with its own context " <>
      "and the same model and tools as you (except `task`), and get back each one's final " <>
      "answer. Use it for independent research or inspection: reading several guides or docs, " <>
      "probing different plugin APIs, reviewing a proposal with fresh eyes. A subagent sees " <>
      "only `context` and its `prompt`, never this conversation, and can't ask anyone " <>
      "anything: give it all it needs and say what to answer with. They share the phone and " <>
      "the Dyn staging copy: never give two of them edits to the same file. Each one costs " <>
      "tokens like a session of its own. Waits for all of them, up to " <>
      "#{div(@timeout_ms, 60_000)} minutes; one still working then is stopped and its answer " <>
      "so far returned."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tasks" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_tasks,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{
                "type" => "string",
                "description" => "A short unique label, e.g. \"camera-api\"."
              },
              "prompt" => %{
                "type" => "string",
                "description" => "The job, complete in itself, and what to answer with."
              }
            },
            "required" => ["name", "prompt"],
            "additionalProperties" => false
          }
        },
        "context" => %{
          "type" => "string",
          "description" => "Shared background put before every task's prompt."
        }
      },
      "required" => ["tasks"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: @timeout_ms

  @impl true
  def run(args, ctx), do: run(args, ctx, deadline_ms: @deadline_ms)

  @doc """
  `run/2` with `opts[:deadline_ms]`: how long the subagents get before the
  ones still running are stopped.
  """
  @spec run(map(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, ctx, opts) do
    with {:ok, tasks} <- tasks(args["tasks"]),
         {:ok, context} <- context(args["context"]),
         {:ok, loop} <- caller_loop(ctx),
         {:ok, config} <- config(loop),
         cap = answer_cap(length(tasks)),
         {:ok, children, guard} <- start(tasks, context, config, cap) do
      try do
        deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :deadline_ms)
        loop_ref = Process.monitor(loop)
        outcome = await(children, loop, loop_ref, deadline)
        Process.demonitor(loop_ref, [:flush])
        {:ok, report(children, outcome, cap)}
      after
        release(children, guard)
      end
    end
  end

  # The answers share one tool result's budget, so none is spilled to an
  # artifact out of the caller's sight; the rest is the headings.
  defp answer_cap(n), do: div(Artifacts.budget() - 1024, n)

  # ── arguments ──

  defp tasks(list) when is_list(list) and list != [] and length(list) <= @max_tasks do
    parsed = Enum.map(list, &task/1)
    names = for {name, _} <- parsed, do: name

    cond do
      :invalid in parsed ->
        {:error, "each task needs a non-empty `name` and `prompt` (strings)"}

      Enum.uniq(names) != names ->
        {:error, "task names must be unique"}

      true ->
        {:ok, parsed}
    end
  end

  defp tasks(_), do: {:error, "`tasks` must be a list of 1-#{@max_tasks} {name, prompt} objects"}

  defp task(%{"name" => name, "prompt" => prompt}) when is_binary(name) and is_binary(prompt) do
    case {String.trim(name), String.trim(prompt)} do
      {"", _} -> :invalid
      {_, ""} -> :invalid
      task -> task
    end
  end

  defp task(_), do: :invalid

  defp context(nil), do: {:ok, ""}
  defp context(text) when is_binary(text), do: {:ok, String.trim(text)}
  defp context(_), do: {:error, "`context` must be a string"}

  defp caller_loop(%{loop: loop}) when is_pid(loop), do: {:ok, loop}
  defp caller_loop(_), do: {:error, "task only runs from an agent loop"}

  defp config(loop) do
    {:ok, Loop.config(loop)}
  catch
    :exit, _ -> {:error, "the calling session's loop is gone"}
  end

  # ── subagents ──

  defp start(tasks, context, %{session: parent, opts: parent_opts}, cap) do
    dir = Path.join(Path.dirname(parent.path), "subagents")

    specs =
      for {name, prompt} <- tasks do
        session = %{Session.new(dir, parent.model, parent.cwd) | title: "task: #{name}"}
        {name, prompt, Keyword.merge(parent_opts, child_opts(parent_opts, session))}
      end

    caller = self()
    ref = make_ref()
    {pid, mon} = spawn_monitor(fn -> guard(caller, ref, specs) end)

    receive do
      {^ref, pids} ->
        children =
          for {{name, prompt, opts}, pid} <- Enum.zip(specs, pids) do
            :ok = Loop.subscribe(pid)
            :ok = Loop.prompt(pid, child_prompt(name, prompt, context, cap))
            %{name: name, pid: pid, ref: Process.monitor(pid), session_id: opts[:session].id}
          end

        {:ok, children, %{pid: pid, ref: ref, mon: mon}}

      {:DOWN, ^mon, :process, _pid, reason} ->
        {:error, "could not start the subagents: #{Exception.format_exit(reason)}"}
    end
  end

  defp child_opts(parent_opts, session) do
    [
      session: session,
      entries: [],
      withhold_tools: Enum.uniq([name() | Keyword.get(parent_opts, :withhold_tools, [])]),
      max_iterations:
        min(
          Keyword.get(parent_opts, :max_iterations, Operator.Core.max_iterations()),
          Operator.Core.max_iterations()
        )
    ]
  end

  defp child_prompt(name, prompt, context, cap) do
    intro =
      "You are a subagent: the main agent started you with its `task` tool for one job, " <>
        "\"#{name}\", alongside others. No one reads this session or answers questions in " <>
        "it: work things out with your tools. The others share this phone and the Dyn " <>
        "staging copy, so only edit files your job names. Your last message is all that goes " <>
        "back, cut at #{cap} bytes: make it the complete answer, not an account of what you " <>
        "did; put anything longer in a workspace file and give its path."

    context = if context == "", do: "", else: "\n\n<context>\n#{context}\n</context>"
    intro <> context <> "\n\n" <> prompt
  end

  # Unlinked loops, so a subagent's crash is only reported. They end when
  # the call is done with them (`release/2`), or once the call's process is
  # gone: it may be killed with no chance to clean up.
  defp guard(caller, ref, specs) do
    caller_ref = Process.monitor(caller)

    pids =
      for {_name, _prompt, opts} <- specs do
        {:ok, pid} = GenServer.start(Loop, opts)
        pid
      end

    send(caller, {ref, pids})

    receive do
      {^ref, :done} -> Enum.each(pids, &shutdown/1)
      {:DOWN, ^caller_ref, :process, _pid, _reason} -> Enum.each(pids, &shutdown/1)
    end
  end

  # Before the call returns: no subagent outlives it, however long the
  # calling process lives on (`eval`'s evaluator lives for the session),
  # and none of their events or monitors is left in its mailbox.
  defp release(children, guard) do
    Enum.each(children, &unsubscribe(&1.pid))
    send(guard.pid, {guard.ref, :done})

    receive do
      {:DOWN, mon, :process, _pid, _reason} when mon == guard.mon -> :ok
    after
      # Each shutdown is bounded; past that, no more waiting.
      length(children) * 11_000 ->
        Process.demonitor(guard.mon, [:flush])
        Enum.each(children, &Process.exit(&1.pid, :kill))
    end

    Enum.each(children, &Process.demonitor(&1.ref, [:flush]))
    flush(Map.new(children, &{&1.session_id, true}))
  end

  defp flush(sessions) do
    receive do
      {:operator_core, sid, _event} when is_map_key(sessions, sid) -> flush(sessions)
    after
      0 -> :ok
    end
  end

  defp unsubscribe(pid) do
    Loop.unsubscribe(pid)
  catch
    :exit, _ -> :ok
  end

  # Stop first: it kills an in-flight model call, which no exit reaches.
  defp shutdown(pid) do
    stop(pid)
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp stop(pid) do
    Loop.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # ── waiting ──

  # `{:done | :timed_out | :stopped, results}`: results by task name, for the
  # subagents whose run ended (`{:ended, reason}`) or that died.
  defp await(children, loop, loop_ref, deadline) do
    by_session = Map.new(children, &{&1.session_id, &1.name})
    by_ref = Map.new(children, &{&1.ref, &1.name})
    ctx = %{by_session: by_session, by_ref: by_ref, loop: loop, loop_ref: loop_ref}
    wait(%{}, ctx, deadline, length(children))
  end

  defp wait(results, _ctx, _deadline, n) when map_size(results) == n, do: {:done, results}

  defp wait(results, ctx, deadline, n) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    %{by_session: by_session, by_ref: by_ref, loop: loop, loop_ref: loop_ref} = ctx

    receive do
      {:operator_core, sid, %{type: :agent_end, reason: reason}}
      when is_map_key(by_session, sid) ->
        wait(Map.put_new(results, by_session[sid], {:ended, reason}), ctx, deadline, n)

      {:operator_core, _sid, _event} ->
        wait(results, ctx, deadline, n)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(by_ref, ref) ->
        wait(Map.put_new(results, by_ref[ref], {:crashed, reason}), ctx, deadline, n)

      {:operator_core_stop, ^loop} ->
        {:stopped, results}

      {:DOWN, ^loop_ref, :process, _pid, _reason} ->
        {:stopped, results}
    after
      left -> {:timed_out, results}
    end
  end

  # ── report ──

  defp report(children, {unfinished, results}, cap) do
    # A stopped run has its text so far written (an interrupted reply as
    # aborted) before `stop/1` returns, so it is read after.
    for c <- children, not Map.has_key?(results, c.name), do: stop(c.pid)

    Enum.map_join(children, "\n\n", fn c ->
      section(c, Map.get(results, c.name, unfinished), entries(c.pid), cap)
    end)
  end

  defp entries(pid) do
    Loop.snapshot(pid).entries
  catch
    :exit, _ -> []
  end

  defp section(child, outcome, entries, cap) do
    {status, detail} = status(outcome, entries)
    text = entries |> answer() |> cut(cap)
    body = if text == "", do: "(no answer)", else: text
    detail = if detail, do: "\n" <> detail, else: ""
    "## #{child.name}: #{status}#{detail}\n\n#{body}"
  end

  defp status({:ended, :done}, _entries), do: {"done", nil}
  defp status({:ended, :error}, entries), do: {"failed", last_problem(entries)}

  # At max_iterations the child's last reply is its wrap-up status, shown as
  # its answer; the notice that asked for it is for the model, not the caller.
  defp status({:ended, :max_iterations}, _entries), do: {"stopped (max_iterations)", nil}
  defp status({:ended, :cost_cap}, entries), do: {"stopped (cost_cap)", last_notice(entries)}

  defp status({:ended, reason}, _entries), do: {"ended (#{reason})", nil}

  defp status({:crashed, reason}, _entries),
    do: {"crashed", reason |> Exception.format_exit() |> String.slice(0, 500)}

  defp status(:timed_out, _entries), do: {"timed out, stopped (its answer so far)", nil}
  defp status(:stopped, _entries), do: {"stopped with your run (its answer so far)", nil}

  # The last assistant message with text: a reply cut short by a stop or an
  # error often has none, and the one before it says what was found.
  defp answer(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"type" => "message", "message" => %{"role" => "assistant"} = m} ->
        case String.trim(Session.text(m["content"])) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end)
  end

  defp last_problem(entries) do
    Enum.find_value(Enum.reverse(entries), fn
      %{"message" => %{"role" => "assistant", "errorMessage" => e}} when is_binary(e) -> e
      %{"type" => "custom_message", "customType" => "operator.error", "content" => c} -> c
      _ -> nil
    end)
  end

  defp last_notice(entries) do
    Enum.find_value(Enum.reverse(entries), fn
      %{"type" => "custom_message", "content" => c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  defp cut(text, cap) when byte_size(text) <= cap, do: text

  defp cut(text, cap) do
    head = text |> binary_part(0, cap) |> valid_prefix()
    head <> "\n[… #{byte_size(text) - byte_size(head)} more bytes cut]"
  end

  # Never end inside a UTF-8 character.
  defp valid_prefix(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
