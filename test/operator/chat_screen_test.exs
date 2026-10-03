defmodule Operator.ChatScreenTest do
  # The screen runs in the test process (Mob.ScreenCase), so the loop's
  # events, the flush / stick timers and the fake native calls all arrive in
  # this mailbox; `pump/2` feeds them to the screen in order. async: false
  # because the native module is swapped through application env.
  use Mob.ScreenCase, async: false

  import Operator.Test.LoopHelpers

  alias Operator.ChatScreen
  alias Operator.ChatScreen.Follow
  alias Operator.Core.Loop
  alias Operator.Core.Session
  alias Operator.Test.FakeLLM
  alias Operator.Test.FakeNative

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    Application.put_env(:operator, :chat_native, FakeNative)
    on_exit(fn -> Application.delete_env(:operator, :chat_native) end)
  end

  defp mount_chat(dir, script, opts \\ []) do
    %{loop: loop} = ctx = start_loop(dir, script, opts)
    :ok = Loop.unsubscribe(loop)
    Map.put(ctx, :view, mount_screen(ChatScreen, %{loop: loop}))
  end

  # Feed loop events and the screen's own timers to it until `until` (an
  # event type or a timer atom) has been handled.
  defp pump(view, until, timeout \\ 2_000) do
    receive do
      {:operator_core, _sid, %{type: type}} = msg ->
        view = render_info(view, msg)
        if type == until, do: view, else: pump(view, until, timeout)

      timer when timer in [:flush, :stick, :clear_toast] ->
        view = render_info(view, timer)
        if timer == until, do: view, else: pump(view, until, timeout)

      {:llm_request, _, _} ->
        pump(view, until, timeout)
    after
      timeout -> flunk("screen never got #{inspect(until)}")
    end
  end

  defp send_text(view, text),
    do: view |> render_info({:change, :draft, text}) |> render_info({:tap, :send})

  defp button?(view, label), do: find(view, :button, text: label) != nil

  test "streams a reply: deltas are batched, partial markup renders sanely, Send/Steer/Stop", %{
    tmp_dir: dir
  } do
    %{view: view} =
      mount_chat(dir, [[{:text, "Hello "}, {:text, "**wor"}, {:sleep, 300}, {:text, "ld**"}]])

    assert_renderable(view)
    assert button?(view, "Send") and not button?(view, "Stop")

    view = view |> send_text("hi") |> pump(:message_update)
    assert button?(view, "Steer") and button?(view, "Stop")
    assert assigns(view).draft == ""
    # the delta waits for the flush tick
    refute text(view) =~ "Hello"

    view = pump(view, :flush)
    assert text(view) =~ "Hello"
    assert text(view) =~ "wor"
    refute text(view) =~ "**"

    view = pump(view, :agent_end)
    assert %{props: %{font: :term_bold}} = find(view, :text, text: "world")
    assert text(view) =~ "› hi"
    assert button?(view, "Send") and not button?(view, "Stop")
    assert_renderable(view)
  end

  test "sending while the agent runs steers it", %{tmp_dir: dir} do
    script = [
      [{:tool_call, "c", "echo", %{"text" => "x", "sleep_ms" => 200}}],
      [{:text, "steered"}]
    ]

    %{view: view, llm: llm} = mount_chat(dir, script)

    view = view |> send_text("start") |> pump(:tool_execution_start)
    view = view |> send_text("focus on y") |> pump(:queue)
    assert text(view) =~ "1 queued"

    view = pump(view, :agent_end)
    [_, second] = FakeLLM.requests(llm)
    assert Enum.any?(second.messages, &(&1.role == :user and hd(&1.content).text == "focus on y"))
    assert text(view) =~ "› focus on y"
    assert text(view) =~ "●"
  end

  test "Stop ends the run and shows the notice", %{tmp_dir: dir} do
    %{view: view} = mount_chat(dir, [[{:text, "partial"}, :block]])
    view = view |> send_text("go") |> pump(:message_update)
    view = view |> render_info({:tap, :stop}) |> pump(:agent_end)

    assert text(view) =~ "partial"
    assert text(view) =~ "Stopped by the user."
    assert button?(view, "Send")
  end

  describe "stick to bottom" do
    test "a burst of rows keeps following; a scroll up stops it", %{tmp_dir: dir} do
      script = [
        [{:text, "one\n"}, {:sleep, 250}, {:text, "two\n"}, {:sleep, 250}, {:text, "three"}]
      ]

      %{view: view} = mount_chat(dir, script)
      assert_received :stick
      Process.put(:fake_scroll_info, FakeNative.index_info(10, 10, 20))

      view = view |> send_text("go") |> pump(:flush)
      assert assigns(view).following
      view = pump(view, :stick)
      assert_received {:scrolled_to, "transcript", +0.0, 19.0}

      # 40 rows landed at once: far from the new bottom, but the user didn't move
      Process.put(:fake_scroll_info, FakeNative.index_info(10, 10, 60))
      view = pump(view, :flush)
      assert assigns(view).following
      view = pump(view, :stick)
      assert_received {:scrolled_to, "transcript", +0.0, 59.0}

      # the user scrolled up: no more scrolling on new output
      Process.put(:fake_scroll_info, FakeNative.index_info(3, 10, 60))
      view = pump(view, :message_end)
      refute assigns(view).following
      refute_receive :stick, 150
    end

    test "the decision: index lists, pixel scroll views, no info" do
      assert Follow.at_bottom?(FakeNative.index_info(10, 10, 20))
      assert Follow.at_bottom?(FakeNative.index_info(9, 10, 20))
      refute Follow.at_bottom?(FakeNative.index_info(5, 10, 20))
      assert Follow.bottom(FakeNative.index_info(0, 5, 20)) == {0.0, 19.0}

      pixel = %{
        kind: :pixel,
        offset: {0.0, 950.0},
        viewport: {0.0, 800.0},
        max_offset: {0.0, 1000.0},
        content: {0.0, 1800.0}
      }

      assert Follow.at_bottom?(pixel)
      refute Follow.at_bottom?(%{pixel | offset: {0.0, 500.0}})
      assert Follow.bottom(pixel) == {0.0, 1000.0}

      assert Follow.decide({:error, :unavailable}, true, 4.0) == {true, 4.0}
      assert Follow.decide({:error, :unavailable}, false, nil) == {false, nil}
    end

    test "the decision over time: follow, burst, scroll up, come back" do
      at = &FakeNative.index_info/3
      assert {true, 10.0} = Follow.decide(at.(10, 10, 20), true, nil)
      assert {true, 10.0} = Follow.decide(at.(10, 10, 60), true, 10.0)
      assert {false, 4.0} = Follow.decide(at.(4, 10, 60), true, 10.0)
      assert {false, 30.0} = Follow.decide(at.(30, 10, 60), false, 4.0)
      assert {true, 49.0} = Follow.decide(at.(49, 10, 60), false, 30.0)

      pixel = %{
        kind: :pixel,
        offset: {0.0, 500.0},
        viewport: {0.0, 800.0},
        max_offset: {0.0, 3000.0}
      }

      assert {true, 500.0} = Follow.decide(pixel, true, 498.0)
      assert {false, 500.0} = Follow.decide(pixel, true, 900.0)
    end
  end

  test "copying: long-press a line, a code block's Copy, copy last reply", %{tmp_dir: dir} do
    reply = "Run:\n```sh\nmix test --only x\n```\nthen **done** ([log](https://l.dev))"
    %{view: view} = mount_chat(dir, [[{:text, reply}]])
    view = view |> send_text("how?") |> pump(:agent_end)

    %{key: key} = Enum.find(assigns(view).done_rev, &(&1.entry["message"]["role"] == "assistant"))
    plain = "Run:\nmix test --only x\nthen done (log (https://l.dev))"

    view = render_info(view, {:long_press, {:copy, key}})
    assert_received {:clipboard, ^plain}
    assert text(view) =~ "Copied #{String.length(plain)} characters"

    copy_button = find(view, :text, text: " Copy ")
    assert copy_button.props.on_tap == {self(), {:copy_code, key, 0}}
    render_info(view, {:tap, {:copy_code, key, 0}})
    assert_received {:clipboard, "mix test --only x"}

    render_info(view, {:tap, :copy_last})
    assert_received {:clipboard, ^plain}
  end

  test "a long transcript renders a bounded window", %{tmp_dir: dir} do
    session =
      Enum.reduce(1..400, Session.new(dir, model(), dir), fn i, s ->
        s |> Session.append(Session.user("question #{i}\nsecond line")) |> elem(0)
      end)

    {:ok, session, entries} = Session.open(session.path, model())
    %{view: view} = mount_chat(dir, [], session: {session, entries})
    # 801 lines: the model_change line plus two per question
    visible = assigns(view).visible
    assert Enum.count(visible) == 301
    assert hd(visible).props.text =~ "show 501 earlier lines"
    assert List.last(visible).props.id == "m400.1"
    assert view |> flatten() |> Enum.count() < 700

    view = render_info(view, {:tap, :show_earlier})
    assert Enum.count(assigns(view).visible) == 601
  end

  test "the model can be changed while idle", %{tmp_dir: dir} do
    %{view: view, loop: loop} = mount_chat(dir, [])

    view =
      view
      |> render_info({:tap, :edit_model})
      |> render_info({:change, :model_draft, "openai/gpt-5-mini"})
      |> render_info({:tap, :save_model})

    assert assigns(view).model == "openrouter:openai/gpt-5-mini"
    assert Loop.snapshot(loop).model == "openrouter:openai/gpt-5-mini"
    # status and cost first, the model's short name last (the line is cut at the end)
    assert text(view) =~ "idle · $0.0000 · 0 tok · gpt-5-mini"
  end
end
