defmodule Operator.Core.Tools.SubagentTest.Router do
  @moduledoc """
  An `Operator.Core.LLM` whose opts are `fn request -> steps end`: the reply
  depends on which session asks (parent or subagent), whatever order the
  concurrent calls arrive in. Steps: `{:text, s}`, `{:tool_call, id, name,
  args}`, `{:hold, test, tag}` (tells the test `{:held, tag, worker_pid}`,
  then waits for `:go`).
  """
  @behaviour Operator.Core.LLM

  @impl true
  def stream(request, route, sink) do
    acc = %{
      text: "",
      thinking: "",
      tool_calls: [],
      usage: %{input_tokens: 10, output_tokens: 5, total_cost: 0.0},
      finish_reason: :stop
    }

    {:ok, Enum.reduce(route.(request), acc, &step(&1, &2, sink))}
  end

  defp step({:text, s}, acc, sink) do
    sink.({:text, s})
    %{acc | text: acc.text <> s}
  end

  defp step({:tool_call, id, name, args}, acc, _sink),
    do: %{
      acc
      | tool_calls: acc.tool_calls ++ [%{"id" => id, "name" => name, "arguments" => args}]
    }

  defp step({:hold, test, tag}, acc, _sink) do
    send(test, {:held, tag, self()})

    receive do
      :go -> acc
    end
  end
end

defmodule Operator.Core.Tools.SubagentTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers
  import Operator.Test.ObserverHelpers, only: [start_current: 3]

  alias Operator.Core.Artifacts
  alias Operator.Core.Current
  alias Operator.Core.Loop
  alias Operator.Core.Session
  alias Operator.Core.Tools.Subagent
  alias Operator.Core.Tools.SubagentTest.Router

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tools [Operator.Test.Tools.Echo, Subagent]

  defp user_text(%{messages: messages}) do
    messages |> Enum.find(&(&1.role == :user)) |> text()
  end

  defp text(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", &(&1.text || ""))

  defp tool_results(%{messages: messages}), do: for(%{role: :tool} = m <- messages, do: text(m))

  defp tool_names(%{tools: tools}), do: Enum.map(tools, & &1.name)

  # The parent calls `task` with `args` on "go", then ends; a subagent's
  # replies come from `child.(request)`.
  defp route(args, child) do
    fn request ->
      case {user_text(request), tool_results(request)} do
        {"go", []} -> [{:tool_call, "t1", "task", args}]
        {"go", _} -> [{:text, "parent done"}]
        _ -> child.(request)
      end
    end
  end

  defp task_result(events) do
    [text] = for %{type: :tool_execution_end, name: "task", text: text} <- events, do: text
    text
  end

  # `inputs` spares the loops a model database lookup (slow the first time).
  @loop_opts [tools: @tools, inputs: [:text]]

  defp start_parent(dir, route), do: start_loop(dir, [], [llm: {Router, route}] ++ @loop_opts)

  test "runs the subagents at the same time and returns each one's answer", %{tmp_dir: dir} do
    test = self()

    args = %{
      "context" => "SHARED NOTES",
      "tasks" => [
        %{"name" => "alpha", "prompt" => "JOB alpha"},
        %{"name" => "beta", "prompt" => "JOB beta"}
      ]
    }

    child = fn request ->
      prompt = user_text(request)
      send(test, {:prompt, prompt})
      job = if prompt =~ "JOB alpha", do: "alpha", else: "beta"
      [{:hold, test, job}, {:text, "#{job} found #{String.length(job)}"}]
    end

    %{loop: loop} = start_parent(dir, route(args, child))
    :ok = Loop.prompt(loop, "go")

    # Both model calls are in flight before either is let go.
    assert_receive {:held, first, w1}, 2_000
    assert_receive {:held, second, w2}, 2_000
    assert Enum.sort([first, second]) == ["alpha", "beta"]
    send(w1, :go)
    send(w2, :go)

    result = task_result(collect(5_000))
    assert result =~ "## alpha: done\n\nalpha found 5"
    assert result =~ "## beta: done\n\nbeta found 4"

    for _ <- 1..2 do
      assert_receive {:prompt, prompt}
      assert prompt =~ "SHARED NOTES"
    end
  end

  test "a long answer is cut to the tasks' share of one tool result, on a character",
       %{tmp_dir: dir} do
    args = %{
      "tasks" => [%{"name" => "a", "prompt" => "JOB a"}, %{"name" => "b", "prompt" => "JOB b"}]
    }

    long = String.duplicate("é", 10_000)
    %{loop: loop} = start_parent(dir, route(args, fn _ -> [{:text, long}] end))
    :ok = Loop.prompt(loop, "go")
    result = task_result(collect(5_000))

    assert String.valid?(result)
    assert byte_size(result) <= Artifacts.budget()
    assert [_, _] = Regex.scan(~r/\[… \d+ more bytes cut\]/, result)
  end

  test "a subagent is not offered task and can't call it", %{tmp_dir: dir} do
    test = self()
    args = %{"tasks" => [%{"name" => "probe", "prompt" => "JOB probe"}]}

    child = fn request ->
      send(test, {:child_request, tool_names(request), tool_results(request)})

      if tool_results(request) == [],
        do: [{:tool_call, "c1", "task", args}],
        else: [{:text, "could not recurse"}]
    end

    parent_route = route(args, child)

    spy = fn request ->
      if user_text(request) == "go", do: send(test, {:parent_tools, tool_names(request)})
      parent_route.(request)
    end

    %{loop: loop} = start_parent(dir, spy)
    :ok = Loop.prompt(loop, "go")
    result = task_result(collect(5_000))

    assert_receive {:parent_tools, parent_tools}
    assert "task" in parent_tools

    assert_receive {:child_request, child_tools, []}
    assert child_tools == ["echo"]
    assert_receive {:child_request, _, ["Tool not found: task. Available tools: echo"]}
    assert result =~ "## probe: done\n\ncould not recurse"
  end

  test "a subagent still running at the deadline is stopped, with its text so far",
       %{tmp_dir: dir} do
    test = self()
    args = %{"tasks" => [%{"name" => "slow", "prompt" => "JOB slow"}]}

    %{loop: parent} =
      start_parent(
        dir,
        route(args, fn _ -> [{:text, "partial findings"}, {:hold, test, :slow}] end)
      )

    call = Task.async(fn -> Subagent.run(args, %{loop: parent}, deadline_ms: 1_000) end)
    assert_receive {:held, :slow, worker}, 2_000
    ref = Process.monitor(worker)

    assert {:ok, result} = Task.await(call, 5_000)
    assert result =~ "## slow: timed out, stopped (its answer so far)\n\npartial findings"
    # Stopping killed its model call.
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
  end

  test "stopping the caller's run stops its subagents", %{tmp_dir: dir} do
    test = self()

    args = %{
      "tasks" => [
        %{"name" => "quick", "prompt" => "JOB quick"},
        %{"name" => "stuck", "prompt" => "JOB stuck"}
      ]
    }

    child = fn request ->
      if user_text(request) =~ "JOB quick",
        do: [{:text, "quick answer"}],
        else: [{:text, "half way"}, {:hold, test, :stuck}]
    end

    %{loop: loop} = start_parent(dir, route(args, child))
    :ok = Loop.prompt(loop, "go")
    assert_receive {:held, :stuck, worker}, 2_000
    ref = Process.monitor(worker)
    # Let `quick` finish first.
    Process.sleep(200)

    :ok = Loop.stop(loop)
    events = collect(5_000)
    result = task_result(events)

    assert result =~ "## quick: done\n\nquick answer"
    assert result =~ "## stuck: stopped with your run (its answer so far)\n\nhalf way"
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
    assert List.last(events).reason == :stopped
  end

  test "a call killed half-way takes its subagents with it", %{tmp_dir: dir} do
    test = self()
    args = %{"tasks" => [%{"name" => "stuck", "prompt" => "JOB stuck"}]}
    %{loop: parent} = start_parent(dir, route(args, fn _ -> [{:hold, test, :stuck}] end))

    call = spawn(fn -> Subagent.run(args, %{loop: parent}) end)
    assert_receive {:held, :stuck, worker}, 2_000
    ref = Process.monitor(worker)

    Process.exit(call, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
  end

  test "the user's session stays current and stays the one to resume", %{tmp_dir: dir} do
    args = %{"tasks" => [%{"name" => "side job", "prompt" => "JOB side"}]}

    %{current: current} =
      start_current(
        dir,
        [],
        [llm: {Router, route(args, fn _ -> [{:text, "side answer"}] end)}] ++ @loop_opts
      )

    loop = Current.current(current)
    :ok = Loop.subscribe(loop)
    :ok = Loop.prompt(loop, "go")
    assert task_result(collect(5_000)) =~ "side answer"

    assert Current.current(current) == loop
    path = Loop.snapshot(loop).path
    assert Session.latest(dir) == path
    assert [%{path: ^path}] = Session.list(dir)

    assert [%{title: "task: side job", path: child_path}] =
             Session.list(Path.join(dir, "subagents"))

    {:ok, child, _entries} = Session.open(child_path, "x")
    assert child.model == Loop.snapshot(loop).model
  end

  test "rejects bad task lists" do
    task = %{"name" => "a", "prompt" => "p"}
    ctx = %{loop: self()}

    assert {:error, _} = Subagent.run(%{"tasks" => []}, ctx)
    assert {:error, _} = Subagent.run(%{"tasks" => List.duplicate(task, 5)}, ctx)
    assert {:error, "task names must be unique"} = Subagent.run(%{"tasks" => [task, task]}, ctx)
    assert {:error, _} = Subagent.run(%{"tasks" => [%{"name" => "a", "prompt" => " "}]}, ctx)
    assert {:error, "task only runs from an agent loop"} = Subagent.run(%{"tasks" => [task]}, %{})
  end
end
