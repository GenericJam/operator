defmodule Operator.Core.LoopTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers

  alias Operator.Core.Loop
  alias Operator.Core.Session
  alias Operator.Core.ToolRunner
  alias Operator.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp result_texts(events) do
    for %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <- events,
        do: {m["toolName"], Session.text(m["content"]), m["isError"]}
  end

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  test "a plain reply: pi's event order, streamed deltas, persisted", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:text, "Hel"}, {:text, "lo"}]])
    :ok = Loop.prompt(loop, "hi")
    events = collect()

    assert shape(events) == [
             :agent_start,
             :turn_start,
             {:message_start, "user"},
             {:message_end, "user"},
             {:message_start, "assistant"},
             :message_update,
             :message_update,
             {:message_end, "assistant"},
             :turn_end,
             :agent_end
           ]

    assert for(%{type: :message_update, delta: d} <- events, do: d) == ["Hel", "lo"]

    %{entry: assistant} =
      Enum.find(
        events,
        &match?(%{type: :message_end, entry: %{"message" => %{"role" => "assistant"}}}, &1)
      )

    assert message(assistant)["stopReason"] == "stop"
    assert Session.text(message(assistant)["content"]) == "Hello"
    assert List.last(events) == %{type: :agent_end, reason: :done}
    assert Loop.snapshot(loop).status == :idle
  end

  test "a tool turn: tools run, results feed the next model call", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "echo", %{"text" => "pong"}}], [{:text, "done"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "ping")
    events = collect()

    assert shape(events) == [
             :agent_start,
             :turn_start,
             {:message_start, "user"},
             {:message_end, "user"},
             {:message_start, "assistant"},
             {:message_end, "assistant"},
             :tool_execution_start,
             :tool_execution_end,
             {:message_start, "toolResult"},
             {:message_end, "toolResult"},
             :turn_end,
             :turn_start,
             {:message_start, "assistant"},
             :message_update,
             {:message_end, "assistant"},
             :turn_end,
             :agent_end
           ]

    [_, second] = FakeLLM.requests(llm)

    assert [
             %{role: :user},
             %{role: :assistant, tool_calls: [_]},
             %{role: :tool, tool_call_id: "c1"} = tool
           ] = second.messages

    assert text_of(tool) == "pong"
    assert Enum.map(second.tools, & &1.name) |> Enum.sort() == ["crash", "echo", "notes", "slow"]
    assert second.max_tokens == 4096
  end

  test "parallel tool calls: run together, results kept in call order", %{tmp_dir: dir} do
    calls = [
      {:tool_call, "a", "echo", %{"text" => "first", "sleep_ms" => 150}},
      {:tool_call, "b", "echo", %{"text" => "second"}}
    ]

    %{loop: loop} = start_loop(dir, [calls, [{:text, "ok"}]])
    :ok = Loop.prompt(loop, "go")
    events = collect()

    tool_events =
      for %{type: t, id: id} <- events,
          t in [:tool_execution_start, :tool_execution_end],
          do: {t, id}

    assert tool_events == [
             {:tool_execution_start, "a"},
             {:tool_execution_start, "b"},
             {:tool_execution_end, "b"},
             {:tool_execution_end, "a"}
           ]

    assert result_texts(events) == [{"echo", "first", false}, {"echo", "second", false}]
  end

  test "a crashing tool and a timed-out tool become error results; the run continues", %{
    tmp_dir: dir
  } do
    calls = [
      {:tool_call, "c", "crash", %{}},
      {:tool_call, "s", "slow", %{}},
      {:tool_call, "x", "nope", %{}}
    ]

    %{loop: loop, llm: llm} = start_loop(dir, [calls, [{:text, "recovered"}]])

    :ok = Loop.prompt(loop, "go")
    events = collect()

    assert [{"crash", crash, true}, {"slow", slow, true}, {"nope", nope, true}] =
             result_texts(events)

    assert crash =~ "Tool crashed" and crash =~ "boom"
    assert slow =~ "timed out after 50 ms"
    assert nope =~ "Tool not found: nope"
    assert [_, _] = FakeLLM.requests(llm)
    assert List.last(events).reason == :done
  end

  test "steer is injected at the next step boundary, not as a new run", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "echo", %{"text" => "x", "sleep_ms" => 150}}], [{:text, "ok"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "start")
    await_event(:tool_execution_start)
    :ok = Loop.steer(loop, "also do y")
    events = collect()

    refute Enum.any?(events, &(&1.type == :agent_start))
    assert Enum.count(events, &(&1.type == :turn_start)) == 1

    # turn 2 opens with the steering message, after the tool batch
    after_results = Enum.drop_while(events, &(&1.type != :turn_end))

    assert [:turn_end, :queue, :turn_start, {:message_start, "user"}, {:message_end, "user"} | _] =
             shape(after_results)

    %{entry: steer} = Enum.find(after_results, &(&1.type == :message_end))
    assert message(steer)["steering"] == true

    [_, second] = FakeLLM.requests(llm)
    assert [_, _, %{role: :tool}, %{role: :user} = last] = second.messages
    assert text_of(last) == "also do y"
  end

  test "follow_up runs once the agent would stop", %{tmp_dir: dir} do
    script = [[{:sleep, 100}, {:text, "first"}], [{:text, "second"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "one")
    await_event(:message_start)
    :ok = Loop.follow_up(loop, "two")
    events = collect()

    # (the first turn_start was consumed above)
    assert Enum.count(events, &(&1.type == :turn_end)) == 2
    assert Enum.count(events, &(&1.type == :agent_end)) == 1
    [first_end | _] = for %{type: :turn_end} = e <- events, do: e
    assert Session.text(message(first_end.entry)["content"]) == "first"
    [_, second] = FakeLLM.requests(llm)
    assert text_of(List.last(second.messages)) == "two"
  end

  test "stop aborts the stream, keeps the partial text and ends the run cleanly", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:text, "partial"}, :block]])
    :ok = Loop.prompt(loop, "go")
    assert_receive {:llm_request, _request, worker}
    await_event(:message_update)
    :ok = Loop.stop(loop)
    events = collect()

    assert [
             {:message_end, "assistant"},
             :turn_end,
             {:message_start, "custom"},
             {:message_end, "custom"},
             :agent_end
           ] =
             shape(events)

    %{entry: aborted} = hd(events)
    assert message(aborted)["stopReason"] == "aborted"
    assert Session.text(message(aborted)["content"]) == "partial"
    assert List.last(events).reason == :stopped
    refute Process.alive?(worker)

    # the loop is usable again
    assert Loop.snapshot(loop).status == :idle
  end

  test "stop during tools lets started tools finish and skips the rest", %{tmp_dir: dir} do
    calls = [
      {:tool_call, "a", "echo", %{"text" => "ran", "sleep_ms" => 150}},
      {:tool_call, "b", "echo", %{"text" => "never"}},
      {:tool_call, "c", "echo", %{"text" => "never"}}
    ]

    %{loop: loop, llm: llm} =
      start_loop(dir, [calls, [{:text, "unreachable"}]], max_tool_concurrency: 1)

    :ok = Loop.prompt(loop, "go")
    await_event(:tool_execution_start)
    :ok = Loop.stop(loop)
    events = collect()

    skipped = ToolRunner.skipped_text()

    assert result_texts(events) == [
             {"echo", "ran", false},
             {"echo", skipped, true},
             {"echo", skipped, true}
           ]

    assert for(%{type: :tool_execution_start, id: id} <- events, do: id) == []
    assert List.last(events).reason == :stopped
    assert [_] = FakeLLM.requests(llm)
  end

  test "max_iterations ends a run that keeps calling tools", %{tmp_dir: dir} do
    call = [{:tool_call, "c", "echo", %{"text" => "again"}}]
    %{loop: loop, llm: llm} = start_loop(dir, [call, call, call], max_iterations: 2)
    :ok = Loop.prompt(loop, "loop forever")
    events = collect()

    assert [_, _] = FakeLLM.requests(llm)
    assert List.last(events).reason == :max_iterations

    %{entry: notice} =
      Enum.find(events, &match?(%{type: :message_end, entry: %{"type" => "custom_message"}}, &1))

    assert notice["content"] =~ "max_iterations"
  end

  test "a 429 is retried with backoff, then the reply goes through", %{tmp_dir: dir} do
    script = [
      [{:error, {:http, 429, "slow down"}}],
      [{:error, {:transport, :closed}}],
      [{:text, "ok"}]
    ]

    %{loop: loop} = start_loop(dir, script)

    :ok = Loop.prompt(loop, "hi")
    events = collect()

    assert [%{attempt: 1, delay_ms: 1}, %{attempt: 2, delay_ms: 2}] =
             for(%{type: :retry} = e <- events, do: e)

    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    assert List.last(events).reason == :done
  end

  test "retries stop after two; a 402 is terminal and tells the user what to do", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:error, {:http, 402, "can only afford 8000"}}]])

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert for(%{type: :retry} <- events, do: :retry) == []
    %{error: error, entry: entry} = Enum.find(events, &(&1.type == :turn_end))
    assert error =~ "can only afford 8000"
    assert error =~ "https://openrouter.ai/settings/credits"
    assert message(entry)["stopReason"] == "error"
    assert message(entry)["errorMessage"] == error
    assert List.last(events).reason == :error

    %{loop: loop2} = start_loop(dir, List.duplicate([{:error, {:http, 503, "busy"}}], 3))

    :ok = Loop.prompt(loop2, "hi")
    events = collect()
    assert [_, _] = for(%{type: :retry} <- events, do: :retry)
    assert List.last(events).reason == :error
  end

  test "before_tool_call can block a call", %{tmp_dir: dir} do
    gate = fn %{"name" => name}, %{session_id: sid} when is_binary(sid) ->
      if name == "echo", do: {:block, "needs approval"}, else: :allow
    end

    script = [[{:tool_call, "c", "echo", %{"text" => "x"}}], [{:text, "ok"}]]
    %{loop: loop} = start_loop(dir, script, before_tool_call: gate)
    :ok = Loop.prompt(loop, "go")
    assert [{"echo", "Blocked before running: needs approval", true}] = result_texts(collect())
  end

  test "prompt while running is refused; steer while idle starts a run", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:sleep, 100}, {:text, "a"}], [{:text, "b"}]])
    :ok = Loop.prompt(loop, "one")
    assert {:error, :running} = Loop.prompt(loop, "two")
    collect()
    :ok = Loop.steer(loop, "three")
    assert [:agent_start | _] = shape(collect())
  end

  test "the session file replays to the exact context the live loop sends", %{tmp_dir: dir} do
    script = [
      [
        {:thinking, "hmm"},
        {:text, "Let me note that."},
        {:tool_call, "n1", "notes", %{"action" => "append", "text" => "milk"}}
      ],
      [{:text, "Noted."}],
      [{:text, "Still here."}]
    ]

    %{loop: loop, session: session} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "remember milk")
    collect()
    assert File.read!(Path.join(dir, "notes.md")) == "milk\n"

    live = Loop.context(loop)
    {:ok, reopened, entries} = Session.open(session.path, "openrouter:unused")
    assert Session.context(entries) == live
    assert reopened.model == model()
    assert [_, _, _, _] = live

    # resume: a new loop on the reopened session continues the same file and chain
    GenServer.stop(loop)

    %{loop: resumed, llm: llm} =
      start_loop(dir, Enum.drop(script, 2), session: {reopened, entries})

    assert Loop.context(resumed) == live
    :ok = Loop.prompt(resumed, "still there?")
    collect()
    [request] = FakeLLM.requests(llm)
    assert Enum.take(request.messages, 4) == live

    {:ok, _, all} = Session.open(session.path, "x")
    ids = Enum.map(all, & &1["id"])
    assert Enum.map(all, & &1["parentId"]) == [nil | Enum.drop(ids, -1)]
  end
end
