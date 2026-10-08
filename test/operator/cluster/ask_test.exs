defmodule Operator.Cluster.AskTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers

  alias Operator.Cluster.Ask
  alias Operator.Core.Loop
  alias Operator.Core.Models
  alias Operator.Test.FakeLLM

  @moduletag :tmp_dir

  # The loop's first model lookup in a fresh VM loads the LLMDB catalog
  # (over a second): done here so the timings below measure the exchange.
  setup_all do
    _ = Models.inputs("anthropic:claude-haiku-4-5")
    :ok
  end

  @peer :"operator_9598e293b8@10.0.0.132"

  defp ask(loop, text, opts \\ []) do
    test = self()

    Task.async(fn ->
      Ask.run(
        loop,
        text,
        @peer,
        [reply: &send(test, {:reply, &1}), late: &send(test, {:late, &1})] ++ opts
      )
    end)
  end

  test "an idle agent takes the question as a new run and its last text goes back", %{
    tmp_dir: dir
  } do
    script = [
      [{:tool_call, "c1", "echo", %{"text" => "thinking"}}],
      [{:text, "Why did the BEAM cross the road? To get to the other node."}]
    ]

    %{loop: loop, llm: llm} = start_loop(dir, script)
    task = ask(loop, "tell me a joke")

    assert_receive {:reply, {:ok, "Why did the BEAM cross the road?" <> _}}, 2_000
    Task.await(task)

    # The model saw who asked; the entry says so too.
    [_, second] = FakeLLM.requests(llm)
    assert Enum.any?(second.messages, &(text_of(&1) == "#{@peer} asks: tell me a joke"))
    question = Enum.find(Loop.snapshot(loop).entries, &get_in(&1, ["message", "ask"]))
    assert question["message"]["from"] == Atom.to_string(@peer)
    assert question["message"]["attribution"] == "user"
  end

  test "a busy agent answers once its current run would stop", %{tmp_dir: dir} do
    script = [[{:sleep, 150}, {:text, "user's answer"}], [{:text, "the asked answer"}]]
    %{loop: loop} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "user's question")
    task = ask(loop, "what's up?")

    assert_receive {:reply, {:ok, "the asked answer"}}, 2_000
    Task.await(task)
  end

  test "a slow answer is first 'still working', then arrives late", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:sleep, 200}, {:text, "finally"}]])
    task = ask(loop, "slow one", reply_ms: 50, late_ms: 2_000)

    assert_receive {:reply, {:ok, "nonode@nohost is still working on it" <> _}}, 1_000
    assert_receive {:late, "finally"}, 2_000
    Task.await(task)
  end

  test "an agent stopped before answering is an error, not silence", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[:block]])
    task = ask(loop, "never answered")
    await_event(:turn_start)
    :ok = Loop.stop(loop)

    assert_receive {:reply, {:error, text}}, 2_000
    assert text =~ "without an answer"
    Task.await(task)
  end

  describe "answer/2" do
    defp entry(role, text, extra \\ %{}),
      do: %{"message" => Map.merge(%{"role" => role, "content" => text}, extra)}

    test "the last assistant text after the question, before the next user message" do
      entries = [
        entry("assistant", "before"),
        entry("user", "q", %{"ask" => "a1"}),
        entry("assistant", "first"),
        entry("toolResult", "r"),
        entry("assistant", ""),
        entry("assistant", "last"),
        entry("user", "next"),
        entry("assistant", "later")
      ]

      assert Ask.answer(entries, "a1") == {:ok, "last"}
      assert Ask.answer([entry("user", "q", %{"ask" => "a1"})], "a1") == :no_text
      assert Ask.answer(entries, "a2") == :absent
    end
  end

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)
end
