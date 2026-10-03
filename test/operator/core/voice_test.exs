defmodule Operator.Core.VoiceTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers, only: [collect: 0]
  import Operator.Test.ObserverHelpers

  alias Operator.Core.Current
  alias Operator.Core.Loop
  alias Operator.Core.Voice
  alias Operator.Test.FakeSpeech

  @moduletag :tmp_dir
  @moduletag :capture_log

  # Never busy unless a test sets :pace.
  defp start(dir, script, setting, opts \\ []) do
    {loop_opts, opts} = Keyword.pop(opts, :loop_opts, [])
    %{current: current} = start_current(dir, script, loop_opts)

    setting_fun = if is_function(setting, 0), do: setting, else: fn -> setting end

    start_observer(
      Voice,
      current,
      Keyword.merge([backend: {FakeSpeech, self()}, setting: setting_fun, pace: {0, 0}], opts)
    )

    loop = Current.current(current)
    :ok = Loop.subscribe(loop)
    loop
  end

  defp run(loop, text) do
    :ok = Loop.prompt(loop, text)
    collect()
  end

  @tool_turn [{:text, "Checking the **notes**."}, {:tool_call, "c1", "echo", %{"text" => "x"}}]

  describe "which events speak" do
    test ":important: a finished run says the first sentence of its final reply", %{
      tmp_dir: dir
    } do
      reply = """
      I renamed the **Notes** screen to `Memo` ([diff](https://example.com/d)). It is live.

      ```elixir
      Memo.open()
      ```
      """

      loop = start(dir, [@tool_turn, [{:text, reply}]], :important)
      run(loop, "rename")
      assert_receive {:speak, "I renamed the Notes screen to Memo (diff)."}
      refute_receive {:speak, _}, 50
    end

    test ":everything: every assistant reply, and nothing more at the end", %{tmp_dir: dir} do
      loop = start(dir, [@tool_turn, [{:text, "All good."}]], :everything)
      run(loop, "check")
      assert_receive {:speak, "Checking the notes."}
      assert_receive {:speak, "All good."}
      refute_receive {:speak, _}, 50
    end

    test ":everything: a run whose final turn has no text still says done", %{tmp_dir: dir} do
      loop = start(dir, [[{:text, ""}]], :everything)
      run(loop, "quiet")
      assert_receive {:speak, "Done."}
    end

    test ":off says nothing; the setting is read at each event", %{tmp_dir: dir} do
      {:ok, setting} = Agent.start_link(fn -> :off end)

      loop =
        start(dir, [[{:text, "First."}], [{:text, "Second."}]], fn -> Agent.get(setting, & &1) end)

      run(loop, "one")
      refute_receive {:speak, _}, 50

      Agent.update(setting, fn _ -> :important end)
      run(loop, "two")
      assert_receive {:speak, "Second."}
    end

    test "a stopped run says so (the aborted reply is not read)", %{tmp_dir: dir} do
      loop = start(dir, [[{:text, "partial"}, {:sleep, 1_000}]], :everything)
      :ok = Loop.prompt(loop, "long")
      :ok = Loop.stop(loop)
      collect()
      assert_receive {:speak, "Stopped."}
      refute_receive {:speak, _}, 50
    end

    test "a failed run says the error's first sentence", %{tmp_dir: dir} do
      loop = start(dir, [[{:error, {:http, 402, "can only afford 8000"}}]], :important)
      run(loop, "expensive")
      assert_receive {:speak, "Error: 402 (payment required): can only afford 8000."}
    end

    test "the step limit says so", %{tmp_dir: dir} do
      loop = start(dir, [@tool_turn], :important, loop_opts: [max_iterations: 1])
      run(loop, "loop forever")
      assert_receive {:speak, "Stopped: too many steps in one run."}
    end
  end

  describe "while speaking" do
    test "a reply is skipped", %{tmp_dir: dir} do
      loop = start(dir, [@tool_turn, [{:text, "All good."}]], :everything, pace: {60_000, 0})
      run(loop, "check")
      assert_receive {:speak, "Checking the notes."}
      refute_receive {:speak, _}, 50
      refute_received :speech_stop
    end

    test "a run-end line interrupts: stop, then speak", %{tmp_dir: dir} do
      loop =
        start(dir, [[{:text, "First."}], [{:error, {:other, "bad"}}]], :important,
          pace: {60_000, 0}
        )

      run(loop, "one")
      assert_receive {:speak, "First."}
      run(loop, "two")
      assert_receive :speech_stop
      assert_receive {:speak, "Error: Model call failed: bad."}
    end
  end

  for mode <- [:error, :raise] do
    test "a failing backend (#{mode}) is logged; the next line is still spoken", %{
      tmp_dir: dir
    } do
      loop =
        start(dir, [[{:text, "First."}], [{:text, "Second."}]], :important,
          backend: {FakeSpeech, {unquote(mode), self()}},
          pace: {60_000, 0}
        )

      run(loop, "one")
      assert_receive {:speak, "First."}
      # The failed utterance doesn't count as playing: no interrupt.
      run(loop, "two")
      assert_receive {:speak, "Second."}
      refute_received :speech_stop
    end
  end

  describe "plain/1" do
    test "drops code, URLs and tags; keeps link and image text" do
      md = """
      See [the docs](https://hexdocs.pm/x) and ![a chart](c.png) at https://example.com now.
      <details>Hidden <b>bold</b></details>

      ```sh
      rm -rf /
      ```
      $$x^2$$
      """

      assert Voice.plain(md) == "See the docs and a chart at now. Hidden bold."
    end

    test "removes heading, quote, list, table and emphasis markup; lines become sentences" do
      md = """
      # Summary
      > **Bold** and *italic*, ~~old~~ and _under_ with `code`, snake_case and $x$
      - [x] first item
      2. second
      ---
      | name | size |
      |------|-----:|
      | a    | 1    |
      """

      assert Voice.plain(md) ==
               "Summary. Bold and italic, old and under with code, snake_case and x. " <>
                 "first item. second. name, size. a, 1."
    end
  end

  describe "summary/1" do
    test "the first sentence" do
      assert Voice.summary("Version 1.5 is out! More later.") == "Version 1.5 is out!"
    end

    test "at most 200 characters, cut at a word" do
      long = String.duplicate("word ", 60) <> "end."
      summary = Voice.summary(long)
      assert String.length(summary) <= 200
      assert summary =~ ~r/^(word )+word…$/
    end
  end

  describe "line/3" do
    test "per setting and reason" do
      run = %{reply: "Done it. Details.", error: nil}
      assert Voice.line(:off, :done, run) == nil
      assert Voice.line(:important, :done, run) == "Done it."
      assert Voice.line(:everything, :done, run) == nil
      assert Voice.line(:important, :done, %{reply: nil, error: nil}) == "Done."
      assert Voice.line(:important, :error, %{reply: nil, error: nil}) == "The run failed."
      assert Voice.line(:everything, :stopped, run) == "Stopped."
    end
  end

  test "a self-change waiting for approval or reverted is said; :off stays quiet", %{
    tmp_dir: dir
  } do
    %{current: current} = start_current(dir, [])
    me = self()

    voice =
      start_observer(Voice, current,
        backend: {FakeSpeech, me},
        setting: fn -> :important end,
        pace: {0, 0},
        keeper: :no_keeper
      )

    send(voice, {:operator_dyn, %{type: :candidate, gen: 3, rationale: "x"}})
    assert_receive {:speak, "A change to Operator, generation 3, needs your approval."}

    send(voice, {:operator_dyn, %{type: :reverted, from: 3, to: 2, reason: "x", crashes: []}})
    assert_receive {:speak, "Generation 3 kept crashing and was reverted."}

    send(voice, {:operator_dyn, %{type: :proven, gen: 2}})
    refute_receive {:speak, _}, 100

    quiet =
      start_observer(Voice, current,
        backend: {FakeSpeech, me},
        setting: fn -> :off end,
        pace: {0, 0},
        keeper: :no_keeper
      )

    send(quiet, {:operator_dyn, %{type: :candidate, gen: 4, rationale: "x"}})
    refute_receive {:speak, _}, 100
  end
end
