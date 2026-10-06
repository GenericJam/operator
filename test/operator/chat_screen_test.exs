defmodule Operator.ChatScreenTest do
  # The screen runs in the test process (Mob.ScreenCase), so the loop's
  # events, the flush / stick timers and the fake native calls all arrive in
  # this mailbox; `pump/2` feeds them to the screen in order. async: false
  # because the native module is swapped through application env.
  use Mob.ScreenCase, async: false

  import Operator.Test.LoopHelpers
  import Operator.Test.ObserverHelpers, only: [start_current: 4]

  alias Operator.Auth.Transfer
  alias Operator.ChatScreen
  alias Operator.ChatScreen.Follow
  alias Operator.Core.ApproveButton
  alias Operator.Core.Loop
  alias Operator.Core.Phone
  alias Operator.Core.Session
  alias Operator.Core.Settings
  alias Operator.Core.Term
  alias Operator.Handoff
  alias Operator.Handoff.Inbox
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
    # 801 lines: the model_change line plus two per question; then the
    # signed-out notice (no provider is signed in here)
    visible = assigns(view).visible
    assert Enum.count(visible) == 302
    assert hd(visible).props.text =~ "show 501 earlier lines"
    assert [%{props: %{id: "m400.1"}}, %{props: %{id: "sign-in"}}] = Enum.take(visible, -2)
    assert view |> flatten() |> Enum.count() < 700

    view = render_info(view, {:tap, :show_earlier})
    assert Enum.count(assigns(view).visible) == 602
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

  test "the top bar is [frontend] and [menu] (no dial); the menu opens on the session's loop",
       %{tmp_dir: dir} do
    %{view: view, loop: loop} = mount_chat(dir, [])
    assert find(view, :text, text: "[frontend]") && find(view, :text, text: "[menu]")
    assert find_all(view, :image) == []
    assert view |> render_info({:tap, :operator_toggle}) |> navigated_to() == Operator.ShellScreen

    view = render_info(view, {:tap, :menu})
    test = self()

    assert {:push, Operator.MenuScreen, %{chat: ^test, loop: ^loop}} =
             view.socket.__mob__.nav_action
  end

  test "a renderer change from the menu re-renders the transcript; code blocks keep Copy", %{
    tmp_dir: dir
  } do
    on_exit(fn -> :persistent_term.erase({Operator.Core.Term, :theme}) end)
    reply = "Run **this**:\n```sh\nmix test\n```\nthen *done*"
    %{view: view} = mount_chat(dir, [[{:text, reply}]])
    view = view |> send_text("how?") |> pump(:agent_end)
    assert find_all(view, :native_view) == []

    Term.put_renderer(:native)
    view = render_info(view, {:operator_menu, :renderer})

    assert ["Run **this**:", "then *done*"] =
             view |> find_all(:native_view) |> Enum.map(& &1.props.text)

    %{key: key} = Enum.find(assigns(view).done_rev, &(&1.entry["message"]["role"] == "assistant"))
    render_info(view, {:tap, {:copy_code, key, 0}})
    assert_received {:clipboard, "mix test"}

    # back to our own parser: the finished messages re-render
    Term.put_renderer(:term)
    view = render_info(view, {:operator_menu, :renderer})
    assert find_all(view, :native_view) == []
    assert text(view) =~ "Run"
    assert %{props: %{font: :term_italic}} = find(view, :text, text: "done")
  end

  test "a model set from the menu shows in the top bar", %{tmp_dir: dir} do
    %{view: view, loop: loop} = mount_chat(dir, [])
    :ok = Loop.set_model(loop, "openai_codex:gpt-5-mini")
    view = pump(view, :model_change)

    assert assigns(view).model == "openai_codex:gpt-5-mini"
    # status and cost first, the model's short name last (the line is cut at the end)
    assert text(view) =~ "idle · $0.0000 · 0 tok · gpt-5-mini"
  end

  test "the status line shows the model's subscription windows, updated after a call",
       %{tmp_dir: dir} do
    alias Operator.Core.Usage
    reset = System.os_time(:second) + 3600

    headers = fn five, week ->
      [
        {"anthropic-ratelimit-unified-5h-utilization", five},
        {"anthropic-ratelimit-unified-5h-reset", "#{reset}"},
        {"anthropic-ratelimit-unified-7d-utilization", week},
        {"anthropic-ratelimit-unified-7d-reset", "#{reset}"}
      ]
    end

    %{view: view, loop: loop} = mount_chat(dir, [[{:text, "Hi."}]])
    # no numbers yet: no figure
    assert text(view) =~ "idle · $0.0000 · 0 tok · claude-haiku-4-5"

    # what the call's headers reported is read once it ends
    :ok =
      Usage.record(dir, model(), %{status: 200, headers: headers.("0.42", "0.18"), usage: %{}})

    codex = [{"x-codex-primary-used-percent", "7"}, {"x-codex-primary-window-minutes", "300"}]
    :ok = Usage.record(dir, "openai_codex:gpt-5-mini", %{status: 200, headers: codex, usage: %{}})
    view = view |> send_text("hello") |> pump(:agent_end)
    assert text(view) =~ "idle · 5h 42% · wk 18% · $0.0010 · 120 tok · claude-haiku-4-5"

    # another model: its provider's windows
    :ok = Loop.set_model(loop, "openai_codex:gpt-5-mini")
    view = pump(view, :model_change)
    assert text(view) =~ "idle · 5h 7% · $0.0010 · 120 tok · gpt-5-mini"
  end

  test "new session and resume, from the menu", %{tmp_dir: dir} do
    start_current(dir, [[{:text, "One."}]], [], Operator.Core.Current)
    view = mount_screen(ChatScreen, %{settings_dir: dir})
    first = assigns(view).sid
    view = view |> send_text("first") |> pump(:agent_end)
    path = Loop.snapshot(assigns(view).loop).path

    view = render_info(view, {:operator_menu, :new_session})
    assert assigns(view).sid != first
    assert Operator.Core.current() == assigns(view).loop
    refute text(view) =~ "› first"

    view = render_info(view, {:operator_menu, {:resume, path}})
    assert assigns(view).sid == first
    assert text(view) =~ "› first"
    assert text(view) =~ "One."
  end

  test "the composer only talks to the agent: the old /login and /models are prompts", %{
    tmp_dir: dir
  } do
    %{view: view, llm: llm} = mount_chat(dir, [[{:text, "ok"}], [{:text, "ok"}]])
    view = view |> send_text("/login anthropic") |> pump(:agent_end)
    view = view |> send_text("/models") |> pump(:agent_end)

    sent =
      for %{messages: messages} <- FakeLLM.requests(llm),
          do: messages |> List.last() |> Map.fetch!(:content) |> hd() |> Map.fetch!(:text)

    assert sent == ["/login anthropic", "/models"]
    assert text(view) =~ "› /login anthropic"
  end

  describe "[attach]" do
    # The pick runs in a task that asks this screen (the test process) for
    # the phone action, like a tool does; feed its request and answer in.
    defp serve_pick(view, action, answer) do
      assert_receive {:phone_request, _ref, _from, ^action, _args} = request
      view = render_info(view, request)
      assert_received {:phone_call, ^action, _}
      view = render_info(view, answer)
      assert_receive {:attached, _, _} = attached
      render_info(view, attached)
    end

    test "file: picked files wait as chips, a tap drops one, the rest go with the message",
         %{tmp_dir: dir} do
      %{view: view, llm: llm} = mount_chat(dir, [[{:text, "a list"}]])
      notes = Path.join(dir, "picked_notes")
      File.write!(notes, "buy milk\n")
      blob = Path.join(dir, "picked_blob")
      File.write!(blob, <<0, 1, 2>>)

      view = render_info(view, {:tap, :attach})
      assert find(view, :text, text: "[photo library]") && find(view, :text, text: "[take photo]")

      items = [%{path: notes, name: "notes.txt"}, %{path: blob, name: "x.bin"}]

      view =
        view
        |> render_info({:tap, {:attach, :files}})
        |> serve_pick(:pick_file, {:files, :picked, items})

      refute find(view, :text, text: "[photo library]")
      assert find(view, :text, text: "[x] notes.txt 9 B")

      assert find(view, :text,
               text: "[x] x.bin 3 B, not text or a picture: work with it through its path"
             )

      view = render_info(view, {:tap, {:unattach, 1}})
      refute text(view) =~ "x.bin"

      view = view |> send_text("what's on it?") |> pump(:agent_end)
      assert assigns(view).attachments == []
      kept = Path.join(dir, "workspace/inbox/notes.txt")
      assert File.read!(kept) == "buy milk\n"

      [%{messages: [%{content: [typed, file]}]}] = FakeLLM.requests(llm)
      assert typed.text == "what's on it?"
      assert file.text =~ ~s|<attachment name="notes.txt" type="text/plain" path="#{kept}">|
      assert file.text =~ "buy milk"
      assert text(view) =~ "› what's on it?"
      assert text(view) =~ "› + notes.txt · 9 B"
    end

    test "photo library and camera: pictures go as image blocks, a message of files only",
         %{tmp_dir: dir} do
      %{view: view, llm: llm} = mount_chat(dir, [[{:text, "a cat"}]])
      photo = Path.join(dir, "picked.png")
      File.write!(photo, <<137, 80, 78, 71>>)
      shot = Path.join(dir, "camera.jpg")
      File.write!(shot, <<0xFF, 0xD8, 0xFF, 0xD9>>)

      view =
        view
        |> render_info({:tap, {:attach, :photos}})
        |> serve_pick(:pick_photos, {:photos, :picked, [%{path: photo, type: "image"}]})

      # take photo asks for the camera first, like camera_photo
      view = render_info(view, {:tap, {:attach, :camera}})
      assert_receive {:phone_request, _, _, :camera_photo, _} = request
      view = view |> render_info(request) |> render_info({:permission, :camera, :granted})
      assert_received {:phone_call, :camera_photo, _}
      view = render_info(view, {:camera, :photo, %{path: shot, width: 1, height: 1}})
      assert_receive {:attached, _, _} = attached
      view = render_info(view, attached)

      assert find(view, :text, text: "[x] picked.png 4 B")
      assert find(view, :text, text: "[x] camera.jpg 4 B")

      view = view |> render_info({:tap, :send}) |> pump(:agent_end)
      [%{messages: [%{content: parts}]}] = FakeLLM.requests(llm)
      assert Enum.map(parts, & &1.type) == [:text, :image, :text, :image]
      assert text(view) =~ "› + picked.png · 4 B"
    end

    test "a cancelled pick changes nothing; a failed one says why", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])

      view =
        view
        |> render_info({:tap, {:attach, :files}})
        |> serve_pick(:pick_file, {:files, :cancelled})

      assert assigns(view).attachments == []
      refute text(view) =~ "attaching…"

      view = render_info(view, {:tap, {:attach, :camera}})
      assert_receive {:phone_request, _, _, :camera_photo, _} = request

      view =
        view |> render_info(request) |> render_info({:permission, :camera, :denied})

      assert_receive {:attached, _, _} = attached
      view = render_info(view, attached)
      assert text(view) =~ "The user didn't allow camera access"
    end

    test "a pick given up on that answers late doesn't end the wait for a newer one",
         %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      notes = Path.join(dir, "picked_notes")
      File.write!(notes, "buy milk\n")

      view = render_info(view, {:tap, {:attach, :photos}})
      assert_receive {:phone_request, _, _, :pick_photos, _} = photos
      view = render_info(view, photos)
      assert text(view) =~ "attaching…"

      # the photo picker hangs: stop waiting, then pick a file instead
      view = render_info(view, {:tap, :stop_attaching})
      refute text(view) =~ "attaching…"
      view = render_info(view, {:tap, {:attach, :files}})
      assert_receive {:phone_request, _, _, :pick_file, _} = files
      view = render_info(view, files)

      # the old pick ends while the file pick is still open
      view = render_info(view, {:photos, :cancelled})
      assert_receive {:attached, _, {:ok, :cancelled}} = late
      view = render_info(view, late)
      assert text(view) =~ "attaching…"

      view = send_text(view, "what's on it?")
      assert assigns(view).draft == "what's on it?"

      view = render_info(view, {:files, :picked, [%{path: notes, name: "notes.txt"}]})
      assert_receive {:attached, _, {:ok, [_]}} = attached
      view = render_info(view, attached)
      refute text(view) =~ "attaching…"
      assert find(view, :text, text: "[x] notes.txt 9 B")
    end
  end

  describe "signed out" do
    setup do
      start_supervised!(Operator.Auth)

      on_exit(fn ->
        for p <- Operator.Auth.providers(), do: Operator.SecureStore.delete("auth:#{p}")
      end)
    end

    test "the transcript says where to sign in, until a provider is signed in", %{tmp_dir: dir} do
      for p <- Operator.Auth.providers(), do: :ok = Operator.Auth.delete(p)
      %{view: view} = mount_chat(dir, [])
      assert text(view) =~ "Not signed in to a model: [menu] › accounts to sign in."

      creds = %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}
      :ok = Operator.Auth.put(:anthropic, creds)
      assert_receive {:operator_auth, :changed} = changed
      view = render_info(view, changed)
      refute text(view) =~ "Not signed in"
    end
  end

  describe "dictation" do
    # The screen hands MobSpeech the engine from config; MobSpeech's scripted
    # Fake engine stands in for Whisper, through MobSpeech's real session.
    # The mic is a plain box: its on_press_in / on_press_out arrive as
    # {:press_in, :mic} / {:press_out, :mic}.
    defp dictate(view, script, on_stop) do
      Application.put_env(
        :operator,
        :dictation_engine,
        {MobSpeech.Engine.Fake, script: script, on_stop: on_stop}
      )

      on_exit(fn -> Application.delete_env(:operator, :dictation_engine) end)
      view |> render_info({:press_in, :mic}) |> speech(:listening)
    end

    # Lift the finger after a real hold (the screen cancels anything under 300 ms).
    defp release(view) do
      Process.sleep(310)
      render_info(view, {:press_out, :mic})
    end

    # Feed the session's {:speech, ...} events to the screen until `until`
    # (:listening, :processing or :idle) has been handled.
    defp speech(view, until) do
      receive do
        {:speech, :state, state} = msg ->
          view = render_info(view, msg)
          if state == until, do: view, else: speech(view, until)

        {:speech, _, _} = msg ->
          speech(render_info(view, msg), until)
      after
        2_000 -> flunk("no {:speech, :state, #{inspect(until)}}")
      end
    end

    test "hold: the transcript lands after what was typed, unsent", %{tmp_dir: dir} do
      %{view: view, loop: loop, llm: llm} = mount_chat(dir, [[{:text, "ok"}]])

      view =
        view
        |> render_info({:change, :draft, "fix the "})
        |> dictate([:listening], [{:final, "flaky test please"}])

      assert assigns(view).dictation == :listening

      view = view |> release() |> speech(:processing)
      assert assigns(view).dictation == :processing

      view = speech(view, :idle)
      assert assigns(view).draft == "fix the flaky test please"
      assert assigns(view).dictation == :idle
      assert FakeLLM.requests(llm) == []
      assert Loop.snapshot(loop).entries == []

      # a second dictation appends to the edited draft, not the old base
      view =
        view
        |> render_info({:change, :draft, "fix the flaky test please, then"})
        |> dictate([:listening], [{:final, "commit"}])
        |> release()
        |> speech(:idle)

      assert assigns(view).draft == "fix the flaky test please, then commit"
    end

    test "a quick tap cancels with a hint; nothing heard says so and keeps the draft", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])

      view =
        view
        |> render_info({:change, :draft, "keep me"})
        |> dictate([:listening], [{:final, "never"}])
        |> render_info({:press_out, :mic})
        |> speech(:idle)

      assert text(view) =~ "Hold mic while you talk"
      assert assigns(view).draft == "keep me"

      view =
        view
        |> dictate([:listening], [{:error, :no_speech}])
        |> release()
        |> speech(:idle)

      assert text(view) =~ "Didn't catch that"
      assert assigns(view).draft == "keep me"
    end

    test "a press_out without its press_in is ignored", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      view = render_info(view, {:press_out, :mic})
      assert assigns(view).dictation == :idle
      refute text(view) =~ "Hold mic while you talk"
    end

    test "no microphone permission: asks the OS, then says what to do", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      view = render_info(view, {:speech, :error, :permission})
      assert_received {:requested_permission, :microphone}
      assert text(view) =~ "hold mic and talk"
    end

    test "a failed speech-model download is reported", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      view = render_info(view, {:mob_whisper, :model, {:error, :network}})
      assert text(view) =~ "Couldn't download the speech model"
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

    test "a candidate shows with its diff; the prompt's pass activates it", %{tmp_dir: dir} do
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

      view = render_info(view, {:approval, "approved", %{"subject" => {:activate, n}}})
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

    test "a cancelled prompt or no screen lock changes nothing; deny discards", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      %{n: n} = propose("notes2")
      view = render_info(view, dyn_event(:candidate))
      subject = {:activate, n}

      view =
        render_info(view, {:approval, "failed", %{"reason" => "canceled", "subject" => subject}})

      assert text(view) =~ "Generation #{n} not activated: the prompt was cancelled"

      view = render_info(view, {:approval, "unavailable", %{"subject" => subject}})
      assert text(view) =~ ApproveButton.why("unavailable", %{})

      refute_received {:confirmed, _}
      assert %{generation: 0, pending: ^n} = Operator.Core.Dyn.status()
      assert button?(view, "approve")

      view = render_info(view, {:tap, :deny_proposal})
      assert %{generation: 0, pending: nil} = Operator.Core.Dyn.status()
      refute button?(view, "approve")
    end

    test "off Android the plain chip approves through the configured approval", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      %{n: n} = propose("plain")
      view = render_info(view, dyn_event(:candidate))

      view = render_info(view, {:tap, :approve_proposal})
      refute_received {:confirmed, _}
      assert %{generation: ^n} = Operator.Core.Dyn.status()
      assert text(view) =~ "Generation #{n} is live"
    end

    test "a proposal made while the screen was away shows at mount", %{tmp_dir: dir} do
      %{n: n} = propose("later")
      %{view: view} = mount_chat(dir, [])
      assert text(view) =~ "proposal G#{n}"
    end
  end

  describe "with the production approval" do
    setup %{tmp_dir: dir} do
      Operator.Test.Dyn.purge_all()
      on_exit(&Operator.Test.Dyn.purge_all/0)
      start_supervised!(Operator.Core.Dyn.Approval.Biometric)

      Operator.Test.Dyn.start_keeper(Path.join(dir, "dyn_data"),
        approval: Operator.Core.Dyn.Approval.Biometric
      )

      :ok
    end

    test "the plain chip can't activate without the screen-lock prompt", %{tmp_dir: dir} do
      %{n: n} =
        Operator.Test.Dyn.propose!(
          %{"gated.ex" => Operator.Test.Dyn.tool("Gated", "gated")},
          "add the gated tool"
        )

      %{view: view} = mount_chat(dir, [])
      view = render_info(view, {:tap, :approve_proposal})
      assert text(view) =~ "Generation #{n} not activated: it needs approving"
      assert %{generation: 0, pending: ^n} = Operator.Core.Dyn.status()
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

      # done: a new request is served again; a denial tells the model what
      # the user can do (the prompt may just have been dismissed)
      ref3 = make_ref()

      view
      |> render_info({:phone_request, ref3, self(), :location, %{}})
      |> render_info({:permission, :location, :denied})

      assert_received {:phone_reply, ^ref3, {:error, text}}
      assert text =~ "The user didn't allow location access"
      assert text =~ "call the tool again"
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

    test "camera_snap: camera permission, then the snap; its errors reach the tool", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      ref = make_ref()
      args = %{facing: :back, flash: :off}

      view = render_info(view, {:phone_request, ref, self(), :camera_snap, args})
      assert_received {:requested_permission, :camera}
      refute_received {:phone_call, :camera_snap, _}

      view = render_info(view, {:permission, :camera, :granted})
      assert_received {:phone_call, :camera_snap, ^args}

      photo = %{path: "/tmp/s.jpg", width: 1568, height: 1176, facing: :back}
      view = render_info(view, {:camera, :snapped, photo})
      assert_received {:phone_reply, ^ref, {:ok, ^photo}}

      ref = make_ref()

      view
      |> render_info({:phone_request, ref, self(), :camera_snap, args})
      |> render_info({:permission, :camera, :granted})
      |> render_info({:camera, :snap_error, :no_camera})

      assert_received {:phone_reply, ^ref, {:error, "This phone has no camera" <> _}}
    end

    test "permission requests: parallel ones for a capability share one request and answer", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      [r1, r2, r3, r4] = [make_ref(), make_ref(), make_ref(), make_ref()]

      view =
        view
        |> render_info({:phone_request, r1, self(), :permission, %{capability: :all_files}})
        |> render_info({:phone_request, r2, self(), :permission, %{capability: :media}})
        |> render_info({:phone_request, r3, self(), :permission, %{capability: :all_files}})

      # two file tools in shared storage at once: one request, no refusal
      assert_received {:requested_permission, :all_files}
      refute_received {:requested_permission, :all_files}
      assert_received {:requested_permission, :media}
      refute_received {:phone_reply, _, _}

      view = render_info(view, {:permission, :media, :granted})
      assert_received {:phone_reply, ^r2, {:ok, :granted}}
      refute_received {:phone_reply, _, _}

      view = render_info(view, {:permission, :all_files, :denied})
      assert_received {:phone_reply, ^r1, {:error, "Operator has no access to the phone's" <> _}}
      assert_received {:phone_reply, ^r3, {:error, "Operator has no access to the phone's" <> _}}

      # answered: the next one asks again; a waiter that gave up doesn't
      # hold it up
      gone = dead_pid()

      view
      |> render_info({:phone_request, make_ref(), gone, :permission, %{capability: :media}})
      |> render_info({:phone_request, r4, self(), :permission, %{capability: :media}})
      |> render_info({:permission, :media, :granted})

      assert_received {:requested_permission, :media}
      assert_received {:requested_permission, :media}
      assert_received {:phone_reply, ^r4, {:ok, :granted}}
    end

    test "a grant starts each waiting action once, and none for a tool that gave up", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      args = %{facing: :back, flash: :off}
      gone = dead_pid()

      # the snap's tool timed out before the user allowed the camera
      view =
        view
        |> render_info({:phone_request, make_ref(), gone, :camera_snap, args})
        |> render_info({:permission, :camera, :granted})

      assert_received {:requested_permission, :camera}
      refute_received {:phone_call, :camera_snap, _}

      # two camera actions wait together: each grant answers both requests,
      # but each action starts once
      [r1, r2] = [make_ref(), make_ref()]

      view =
        view
        |> render_info({:phone_request, r1, self(), :camera_photo, %{}})
        |> render_info({:phone_request, r2, self(), :camera_snap, args})
        |> render_info({:permission, :camera, :granted})

      assert_received {:phone_call, :camera_photo, %{}}
      assert_received {:phone_call, :camera_snap, ^args}

      view = render_info(view, {:permission, :camera, :granted})
      refute_received {:phone_call, _, _}

      view
      |> render_info({:camera, :cancelled})
      |> render_info({:camera, :snap_error, :busy})

      assert_received {:phone_reply, ^r1, {:ok, :cancelled}}
      assert_received {:phone_reply, ^r2, {:error, "The camera is busy" <> _}}
    end

    test "pick_file opens the document picker and relays what was picked", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      ref = make_ref()

      view = render_info(view, {:phone_request, ref, self(), :pick_file, %{types: [:any]}})
      assert_received {:phone_call, :pick_file, %{types: [:any]}}
      items = [%{path: "/tmp/a.pdf", name: "a.pdf", mime: "application/pdf", size: 3}]
      view = render_info(view, {:files, :picked, items})
      assert_received {:phone_reply, ^ref, {:ok, ^items}}

      ref = make_ref()

      view
      |> render_info({:phone_request, ref, self(), :pick_file, %{types: [:any]}})
      |> render_info({:files, :cancelled})

      assert_received {:phone_reply, ^ref, {:ok, :cancelled}}
    end

    test "an action whose native side can't start is answered at once, not left waiting", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_chat(dir, [])
      Process.put(:fake_native_result, {:error, :unavailable})
      [r1, r2] = [make_ref(), make_ref()]

      view =
        view
        |> render_info({:phone_request, r1, self(), :pick_photos, %{max: 1}})
        |> render_info({:phone_request, r2, self(), :location, %{}})

      assert_received {:phone_reply, ^r1, {:error, "Couldn't start pick_photos: :unavailable"}}
      assert_received {:phone_reply, ^r2, {:error, "Couldn't start location: :unavailable"}}
      assert assigns(view).phone == %{}

      # nothing is left waiting, so the next request isn't refused as a duplicate
      Process.delete(:fake_native_result)
      r3 = make_ref()
      render_info(view, {:phone_request, r3, self(), :pick_photos, %{max: 1}})
      assert_received {:phone_call, :pick_photos, %{max: 1}}
      refute_received {:phone_reply, ^r3, _}
    end
  end

  # A tool process that has already given up.
  defp dead_pid do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
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

  describe "operator:// links" do
    # What mob delivers for a link the app was opened with (Mob.Link).
    defp opened(link), do: {:link, %{url: link, source: :running}}

    test "a handoff's last part opens a new session with it as the first message; " <>
           "the model sees it with the next prompt, not before",
         %{tmp_dir: dir} do
      %{llm: llm} = start_current(dir, [[{:text, "On it."}]], [], Operator.Core.Current)
      start_supervised!({Inbox, dir: dir})

      summary = "## Goal\n" <> Base.encode64(:crypto.strong_rand_bytes(2_400))
      handoff = %{title: "Ship it", cwd: "/Users/kevin/code/operator", summary: summary}
      [first | rest] = links = Handoff.encode(handoff)

      view = mount_screen(ChatScreen, %{settings_dir: dir})
      shown = assigns(view).sid

      view = render_info(view, opened(first))
      assert text(view) =~ "Handoff 1 of #{length(links)} received: scan the rest"
      assert assigns(view).sid == shown

      view = Enum.reduce(rest, view, &render_info(&2, opened(&1)))
      loop = assigns(view).loop
      assert assigns(view).sid != shown
      assert Operator.Core.current() == loop
      assert text(view) =~ "Handoff from omp on the Mac (project /Users/kevin/code/operator)"
      assert %{title: "Ship it", status: :idle, path: path} = Loop.snapshot(loop)
      assert File.read!(path) =~ "Handoff from omp on the Mac"
      assert FakeLLM.requests(llm) == []

      view |> send_text("carry on") |> pump(:agent_end)
      assert [%{messages: messages}] = FakeLLM.requests(llm)
      assert [framed, "carry on"] = for(m <- messages, do: Enum.map_join(m.content, & &1.text))
      assert framed =~ summary
    end

    test "a login link opens the scanner at the six words, also when Diagnostics forwards it",
         %{tmp_dir: dir} do
      {link, _words} = Transfer.seal(:anthropic, %{"type" => "oauth", "refresh" => "r"})

      %{view: view} = mount_chat(dir, [])
      view = render_info(view, opened(link))
      assert {:push, Operator.LoginScanScreen, %{link: ^link}} = view.socket.__mob__.nav_action

      %{loop: loop} = start_loop(dir, [])
      view = mount_screen(ChatScreen, %{loop: loop, settings_dir: dir, link: link})
      assert_received {:operator_link, ^link} = forwarded
      view = render_info(view, forwarded)
      assert {:push, Operator.LoginScanScreen, %{link: ^link}} = view.socket.__mob__.nav_action
    end

    test "a QR that isn't Operator's is said plainly", %{tmp_dir: dir} do
      %{view: view} = mount_chat(dir, [])
      view = render_info(view, opened("operator://elsewhere?x=1"))
      assert text(view) =~ "That QR isn't an Operator code."
    end
  end
end
