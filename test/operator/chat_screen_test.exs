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
  alias Operator.Core.Phone
  alias Operator.Core.Session
  alias Operator.Core.Settings
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
    Map.put(ctx, :view, mount_screen(ChatScreen, %{loop: loop, settings_dir: dir}))
  end

  # Feed loop events and the screen's own timers to it until `until` (an
  # event type or a timer atom) has been handled.
  defp pump(view, until, timeout \\ 2_000) do
    receive do
      {:operator_core, _sid, %{type: type}} = msg ->
        view = render_info(view, msg)
        if type == until, do: view, else: pump(view, until, timeout)

      timer when timer in [:flush, :stick] ->
        view = render_info(view, timer)
        if timer == until, do: view, else: pump(view, until, timeout)

      {:clear_toast, _text} = timer ->
        view = render_info(view, timer)
        if until == :clear_toast, do: view, else: pump(view, until, timeout)

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

  test "a compaction shows while it runs and leaves a notice line", %{tmp_dir: dir} do
    script = [[{:text, "r1"}], [{:sleep, 100}, {:text, "SUMMARY"}], [{:text, "r2"}]]
    # compaction above 3400 estimated tokens; each message is 2000, the
    # newest is kept
    %{view: view} =
      mount_chat(dir, script,
        context_window: 4000,
        keep_recent_tokens: 1500,
        tools: [Operator.Test.Tools.Echo]
      )

    view = view |> send_text(String.duplicate("a", 8000)) |> pump(:agent_end)
    view = view |> send_text(String.duplicate("b", 8000)) |> pump(:compaction_start)
    assert text(view) =~ "compacting context…"

    view = pump(view, :agent_end)
    assert text(view) =~ "· context compacted:"
    assert text(view) =~ "r2"
    assert_renderable(view)
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

    test "the decision inside one reply taller than the screen (Android px offsets)" do
      at = &FakeNative.index_info/5
      # the streaming reply is the last item; we stuck to its bottom
      assert {true, {5.0, 1200.0}} = Follow.decide(at.(5, 1, 6, 1200, true), true, nil)
      # it grew while streaming: same position, no longer at the end; keep following
      assert {true, {5.0, 1200.0}} = Follow.decide(at.(5, 1, 6, 1200, false), true, {5.0, 1200.0})
      # the user scrolled up inside it: same index, fewer px; stop
      assert {false, {5.0, 400.0}} = Follow.decide(at.(5, 1, 6, 400, false), true, {5.0, 1200.0})
      # near its top is not the bottom (index math alone would say it is)
      assert {false, _} = Follow.decide(at.(5, 1, 6, 400, false), false, {5.0, 400.0})
      # back at the end: resume
      assert {true, _} = Follow.decide(at.(5, 1, 6, 1900, true), false, {5.0, 400.0})
      # rows replaced under the reader nudged px back, still at the end: keep following
      assert {true, _} = Follow.decide(at.(5, 1, 6, 900, true), true, {5.0, 1900.0})
    end

    test "a stick that lands short of the end (rows not laid out yet) retries", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      # right after mount the list isn't registered yet
      Process.put(:fake_scroll_info, {:error, :not_found})
      render_info(view, :stick)
      assert_receive {:stick, 3}, 500

      Process.put(:fake_scroll_info, FakeNative.index_info(0, 3, 3, 0, false))
      render_info(view, {:stick, 3})
      assert_receive {:stick, 2}, 500

      Process.put(:fake_scroll_info, FakeNative.index_info(2, 1, 3, 646, true))
      render_info(view, {:stick, 3})
      refute_receive {:stick, _}, 300
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

  test "the window holds at most max_native native views (mob has 256 component slots)" do
    n = fn id -> %{type: :native_view, props: %{id: id}} end
    t = fn id -> %{type: :wrap, props: %{id: id}} end
    older = %{rows: [n.(:b1), n.(:b2)]}
    newer = %{rows: [t.("a1"), n.(:a2)]}

    assert ChatScreen.window([newer, older], [n.(:s)], 10, 3) ==
             {[n.(:b2), t.("a1"), n.(:a2), n.(:s)], 1}

    assert ChatScreen.window([newer, older], [n.(:s)], 2, 3) == {[n.(:a2), n.(:s)], 3}
  end

  test "the md chip switches to native Markdown views; code blocks keep Copy", %{tmp_dir: dir} do
    on_exit(fn -> :persistent_term.erase({Operator.Core.Term, :theme}) end)
    reply = "Run **this**:\n```sh\nmix test\n```\nthen *done*"
    %{view: view} = mount_chat(dir, [[{:text, reply}]])
    assert button?(view, "md:term")

    view = view |> render_info({:tap, :toggle_renderer}) |> send_text("how?")
    assert button?(view, "md:native")
    view = pump(view, :agent_end)

    assert ["Run **this**:", "then *done*"] =
             view |> find_all(:native_view) |> Enum.map(& &1.props.text)

    %{key: key} = Enum.find(assigns(view).done_rev, &(&1.entry["message"]["role"] == "assistant"))
    render_info(view, {:tap, {:copy_code, key, 0}})
    assert_received {:clipboard, "mix test"}

    # back to our own parser: the finished messages re-render
    view = render_info(view, {:tap, :toggle_renderer})
    assert find_all(view, :native_view) == []
    assert text(view) =~ "Run"
    assert %{props: %{font: :term_italic}} = find(view, :text, text: "done")
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

  describe "dictation" do
    test "streams after what was typed, the final text replaces the partials", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])

      view =
        view
        |> render_info({:change, :draft, "fix the "})
        |> render_info({:dictation, "state", %{"state" => "listening"}})
        |> render_info({:dictation, "partial", %{"text" => "flaky"}})
        |> render_info({:dictation, "partial", %{"text" => "flaky test"}})

      assert assigns(view).draft == "fix the flaky test"

      view =
        view
        |> render_info({:dictation, "final", %{"text" => "flaky test please", "send" => false}})
        |> render_info({:dictation, "state", %{"state" => "idle"}})

      assert assigns(view).draft == "fix the flaky test please"

      # a second dictation appends to the edited draft, not the old base
      view =
        view
        |> render_info({:change, :draft, "fix the flaky test please, then"})
        |> render_info({:dictation, "state", %{"state" => "listening"}})
        |> render_info({:dictation, "final", %{"text" => "commit", "send" => false}})

      assert assigns(view).draft == "fix the flaky test please, then commit"
    end

    test "long-press dictation sends when done; nothing heard leaves the draft", %{tmp_dir: dir} do
      %{view: view, loop: loop} = mount_chat(dir, [[{:text, "ok"}]])

      view =
        view
        |> render_info({:dictation, "state", %{"state" => "listening"}})
        |> render_info({:dictation, "final", %{"text" => "", "send" => false}})

      assert assigns(view).draft == ""

      view =
        view
        |> render_info({:dictation, "state", %{"state" => "listening"}})
        |> render_info({:dictation, "final", %{"text" => "say hi", "send" => true}})
        |> pump(:agent_end)

      assert assigns(view).draft == ""

      assert Enum.any?(
               Loop.snapshot(loop).entries,
               &(&1["message"]["role"] == "user" and
                   hd(&1["message"]["content"])["text"] == "say hi")
             )
    end

    test "no microphone permission: asks the OS, then says what to do", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      view = render_info(view, {:dictation, "needs_permission", %{}})
      assert_received {:requested_permission, :microphone}
      assert text(view) =~ "tap mic again"

      view = render_info(view, {:dictation, "error", %{"reason" => "no_speech"}})
      assert text(view) =~ "Didn't catch that"
    end
  end

  test "the first send asks for notifications, once", %{tmp_dir: dir} do
    %{view: view} = mount_chat(dir, [[{:text, "a"}], [{:text, "b"}]])
    view = view |> send_text("one") |> pump(:agent_end)
    assert_received {:requested_permission, :notifications}
    view |> send_text("two") |> pump(:agent_end)
    refute_received {:requested_permission, :notifications}
  end

  test "[voice:…] cycles off → important → everything and persists it", %{tmp_dir: dir} do
    %{view: view} = mount_chat(dir, [])
    assert text(view) =~ "[voice:important]"

    view = render_info(view, {:tap, :cycle_voice})
    assert text(view) =~ "[voice:everything]"
    assert Settings.voice(dir) == :everything

    view = render_info(view, {:tap, :cycle_voice})
    assert text(view) =~ "[voice:off]"
    assert Settings.voice(dir) == :off
  end

  describe "self-modification proposals" do
    setup %{tmp_dir: dir} do
      Operator.Test.Dyn.purge_all()
      on_exit(&Operator.Test.Dyn.purge_all/0)
      Operator.Test.Dyn.start_keeper(Path.join(dir, "dyn_data"))
      :ok
    end

    defp propose(name) do
      Operator.Test.Dyn.propose!(
        %{"#{name}.ex" => Operator.Test.Dyn.tool(Macro.camelize(name), name)},
        "add the #{name} tool"
      )
    end

    defp dyn_event(type) do
      receive do
        {:operator_dyn, %{type: ^type}} = msg -> msg
      after
        2_000 -> flunk("no #{type} event")
      end
    end

    test "a candidate shows with its diff; the fingerprint activates it", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      refute button?(view, "approve")

      %{n: n} = propose("weather")
      view = render_info(view, dyn_event(:candidate))

      assert button?(view, "approve") and button?(view, "deny")
      assert text(view) =~ "proposal G#{n}"
      # mixed-style words are separate nodes joined by no-break spaces
      shown = view |> text() |> String.replace(~r/[\s\x{00A0}]+/u, " ")
      assert shown =~ "Proposal: generation #{n}"
      assert shown =~ "add the weather tool"
      assert shown =~ "+defmodule Operator.Dyn.Weather do"

      view = render_info(view, {:tap, :approve_proposal})
      assert_received {:authenticate, "Activate Operator generation " <> _}
      assert text(view) =~ "waiting for your fingerprint"

      view = render_info(view, {:biometric, :success})
      assert_received {:confirmed, {:activate, ^n}}
      assert %{generation: ^n, status: :probation} = Operator.Core.Dyn.status()
      refute button?(view, "approve")
      assert text(view) =~ "Generation #{n} is live"

      # the Keeper's own event for it doesn't replace (or cut short) that toast
      view = render_info(view, dyn_event(:activated))
      assert text(view) =~ "Generation #{n} is live"
      view = render_info(view, {:clear_toast, "Generation #{n} activated (on probation)"})
      assert text(view) =~ "Generation #{n} is live"
    end

    test "a failed fingerprint changes nothing; deny discards", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      %{n: n} = propose("notes2")
      view = render_info(view, dyn_event(:candidate))

      view =
        view
        |> render_info({:tap, :approve_proposal})
        |> render_info({:biometric, :failure})

      assert text(view) =~ "not activated: the check failed"
      assert %{generation: 0, pending: ^n} = Operator.Core.Dyn.status()
      assert button?(view, "approve")

      view = render_info(view, {:tap, :deny_proposal})
      assert %{generation: 0, pending: nil} = Operator.Core.Dyn.status()
      refute button?(view, "approve")
    end

    test "a proposal made while the screen was away shows at mount", %{tmp_dir: dir} do
      %{n: n} = propose("later")
      %{view: view} = mount_chat(dir, [])
      assert text(view) =~ "proposal G#{n}"
    end
  end

  describe "phone actions for tools" do
    test "location: permission first, then one fix back to the asking tool", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      ref = make_ref()

      view = render_info(view, {:phone_request, ref, self(), :location, %{}})
      assert_received {:requested_permission, :location}
      refute_received {:phone_call, :location, _}

      # a second location request while the first waits is refused
      ref2 = make_ref()
      view = render_info(view, {:phone_request, ref2, self(), :location, %{}})
      assert_received {:phone_reply, ^ref2, {:error, "Another location request" <> _}}

      view = render_info(view, {:permission, :location, :granted})
      assert_received {:phone_call, :location, %{}}

      fix = %{lat: 45.5, lon: -73.6, accuracy: 9.0, altitude: 30.0}
      view = render_info(view, {:location, fix})
      assert_received {:phone_reply, ^ref, {:ok, ^fix}}

      # done: a new request is served again; a denial answers with an error
      ref3 = make_ref()

      view
      |> render_info({:phone_request, ref3, self(), :location, %{}})
      |> render_info({:permission, :location, :denied})

      assert_received {:phone_reply, ^ref3, {:error, "The user didn't allow location access."}}
    end

    test "notify is answered with its id at once; photos and camera relay the plugin", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      ref = make_ref()

      view =
        render_info(
          view,
          {:phone_request, ref, self(), :notify, %{title: "t", body: "b", in_seconds: 60}}
        )

      assert_received {:phone_call, :notify, %{id: "operator-" <> _ = id, in_seconds: 60}}
      assert_received {:phone_reply, ^ref, {:ok, ^id}}

      ref = make_ref()
      view = render_info(view, {:phone_request, ref, self(), :pick_photos, %{max: 2}})
      assert_received {:phone_call, :pick_photos, %{max: 2}}
      view = render_info(view, {:photos, :picked, [%{display_name: "a.jpg"}]})
      assert_received {:phone_reply, ^ref, {:ok, [%{display_name: "a.jpg"}]}}

      ref = make_ref()

      view =
        view
        |> render_info({:phone_request, ref, self(), :camera_photo, %{}})
        |> render_info({:permission, :camera, :granted})
        |> render_info({:camera, :cancelled})

      assert_received {:phone_reply, ^ref, {:ok, :cancelled}}
      assert_received {:requested_permission, :camera}

      # in the background Android won't open the camera: refused at once
      ref = make_ref()

      view
      |> render_info({:mob_device, :did_enter_background})
      |> render_info({:phone_request, ref, self(), :camera_photo, %{}})

      assert_received {:phone_reply, ^ref, {:error, "Operator isn't on screen" <> _}}
      refute_received {:requested_permission, :camera}
    end
  end

  test "phone tools: no chat screen, a clear error; their selftests pass" do
    host_gone = spawn(fn -> :ok end)
    Process.sleep(10)

    assert {:error, "The chat screen went away" <> _} =
             Phone.request(:location, %{}, 1_000, host_gone)

    assert {:error, "The Operator chat screen isn't running" <> _} =
             Phone.request(:location, %{}, 1_000, nil)

    for tool <- [
          Operator.Core.Tools.Location,
          Operator.Core.Tools.Notify,
          Operator.Core.Tools.CameraPhoto,
          Operator.Core.Tools.PickPhotos
        ] do
      assert tool.selftest() == :ok, inspect(tool)
    end
  end
end
