defmodule Operator.MenuScreenTest do
  # async: false: the sign-ins (Operator.Auth, Operator.Auth.Login) and the
  # renderer (Operator.Core.Term's theme) are app-wide.
  use Mob.ScreenCase, async: false

  import Operator.Test.LoopHelpers

  alias Operator.Auth
  alias Operator.Core.Loop
  alias Operator.Core.Models
  alias Operator.Core.Session
  alias Operator.Core.Term
  alias Operator.MenuScreen
  alias Operator.Test.FlakySecureStore

  @moduletag :tmp_dir
  @moduletag :capture_log

  @creds %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}

  setup do
    start_supervised!(Auth)
    for p <- Auth.providers(), do: :ok = Auth.delete(p)
    on_exit(fn -> for p <- Auth.providers(), do: Operator.SecureStore.delete("auth:#{p}") end)
  end

  # The menu over a chat: this test process stands in for the chat screen.
  defp mount_menu(dir, page, script \\ []) do
    %{loop: loop} = ctx = start_loop(dir, script)
    Map.put(ctx, :view, mount_on(loop, dir, page))
  end

  # What the chat passes: its loop, the session's model and file.
  defp mount_on(loop, dir, page) do
    %{model: model, path: path} = Loop.snapshot(loop)
    params = %{chat: self(), loop: loop, model: model, path: path, page: page, sessions_dir: dir}
    mount_screen(MenuScreen, params)
  end

  defp nav(view), do: view.socket.__mob__.nav_action

  describe "main page" do
    test "shows every setting; each line opens its page", %{tmp_dir: dir} do
      :ok = Auth.put(:anthropic, Map.put(@creds, "email", "k@example.com"))
      %{view: view, loop: loop} = mount_menu(dir, :main)
      assert_renderable(view)

      shown = text(view)
      assert shown =~ "[frontend]"
      assert shown =~ "[back]"
      assert shown =~ "Claude (Anthropic)"
      assert shown =~ "k@example.com"
      assert shown =~ "ChatGPT (OpenAI Codex)"
      assert shown =~ "not signed in"
      assert shown =~ "claude-haiku-4-5"
      assert shown =~ "new session"
      assert shown =~ "resume a session"
      assert shown =~ "renderer: md:"
      assert shown =~ "diagnostics"

      test = self()

      for page <- [:accounts, :model, :sessions] do
        assert {:push, MenuScreen, %{page: ^page, chat: ^test, loop: ^loop, sessions_dir: ^dir}} =
                 view |> render_info({:tap, {:open, page}}) |> nav()
      end

      assert view |> render_info({:tap, :diagnostics}) |> navigated_to() ==
               Operator.DiagnosticsScreen

      %{model: model, path: path} = Loop.snapshot(loop)

      assert {:push, Operator.UsageScreen, %{model: ^model, path: ^path}} =
               view |> render_info({:tap, :usage}) |> nav()

      assert view |> render_info({:tap, :back}) |> nav() == {:pop}

      assert view |> render_info({:tap, :operator_toggle}) |> navigated_to() ==
               Operator.ShellScreen
    end

    test "the renderer flips in place and tells the chat", %{tmp_dir: dir} do
      on_exit(fn -> :persistent_term.erase({Operator.Core.Term, :theme}) end)
      Term.put_renderer(:term)
      %{view: view} = mount_menu(dir, :main)
      assert text(view) =~ "renderer: md:term"

      view = render_info(view, {:tap, :toggle_renderer})
      assert Term.renderer() == :native
      assert_received {:operator_menu, :renderer}
      assert text(view) =~ "renderer: md:native"
      assert nav(view) == nil

      render_info(view, {:tap, :toggle_renderer})
      assert Term.renderer() == :term
    end

    test "new session: the chat starts it, the menu returns to the chat", %{tmp_dir: dir} do
      %{view: view} = mount_menu(dir, :main)
      assert view |> render_info({:tap, :new_session}) |> nav() == {:pop_to, Operator.ChatScreen}
      assert_received {:operator_menu, :new_session}
    end

    test "a sign-in elsewhere (a QR scan) updates the accounts lines", %{tmp_dir: dir} do
      %{view: view} = mount_menu(dir, :main)
      :ok = Auth.put(:openai_codex, Map.put(@creds, "email", "c@example.com"))
      assert_receive {:operator_auth, :changed} = changed
      assert view |> render_info(changed) |> text() =~ "c@example.com"
    end
  end

  describe "accounts" do
    setup do
      {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      test = self()

      token_endpoint = fn _req ->
        body = %{
          "access_token" => "at",
          "refresh_token" => "rt",
          "expires_in" => 28_800,
          "account" => %{"email_address" => "k@example.com"}
        }

        Req.Response.new(status: 200, body: Jason.encode!(body))
      end

      start_supervised!(
        {Operator.Auth.Login,
         open_url: fn url ->
           send(test, {:opened, url})
           :ok
         end,
         redirect: fn _provider -> "http://localhost:#{port}/callback" end,
         respond: token_endpoint}
      )

      :ok
    end

    test "sign in with the browser, pasting the code the page shows; then sign out", %{
      tmp_dir: dir
    } do
      %{view: view} = mount_menu(dir, :accounts)
      assert_renderable(view)
      assert text(view) =~ "Claude (Anthropic)"
      assert text(view) =~ "not signed in"
      assert find(view, :text_field) == nil

      view = render_info(view, {:tap, {:sign_in, :anthropic}})
      assert_received {:opened, "https://claude.ai/oauth/authorize?" <> query}
      assert text(view) =~ "Opening claude.ai: sign in there, then come back to Operator."

      # A code from another sign-in is refused; the right one finishes it.
      assert find(view, :text_field, placeholder: "code#state")
      view = view |> render_info({:change, :code, "x#other"}) |> render_info({:tap, :paste_code})
      assert text(view) =~ "That code is from another sign-in"

      state = URI.decode_query(query)["state"]

      view =
        view
        |> render_info({:change, :code, "the-code##{state}"})
        |> render_info({:submit, :code})

      assert text(view) =~ "Code received"

      assert_receive {:operator_login, :anthropic, :ok} = done, 2_000
      view = render_info(view, done)
      assert text(view) =~ "Signed in to Claude (Anthropic) as k@example.com."
      assert text(view) =~ "signed in as k@example.com · token good for 7 h"
      assert Auth.signed_in?(:anthropic)
      assert find(view, :text_field) == nil

      # Signing out asks first; cancel keeps it.
      view = render_info(view, {:tap, {:sign_out, :anthropic}})
      assert text(view) =~ "[confirm sign out]"
      view = render_info(view, {:tap, :cancel_sign_out})
      refute text(view) =~ "[confirm sign out]"
      assert Auth.signed_in?(:anthropic)

      view =
        view
        |> render_info({:tap, {:sign_out, :anthropic}})
        |> render_info({:tap, {:confirm_sign_out, :anthropic}})

      assert text(view) =~ "Signed out of Claude (Anthropic)."
      refute Auth.signed_in?(:anthropic)
    end

    test "the accounts page reopened mid sign-in keeps the code field and gets the result", %{
      tmp_dir: dir
    } do
      %{view: first, loop: loop} = mount_menu(dir, :accounts)
      render_info(first, {:tap, {:sign_in, :anthropic}})
      assert_received {:opened, "https://claude.ai/oauth/authorize?" <> query}

      # [back], then accounts again: a new page process
      view = mount_on(loop, dir, :accounts)
      assert find(view, :text_field, placeholder: "code#state")

      state = URI.decode_query(query)["state"]

      view =
        view |> render_info({:change, :code, "c##{state}"}) |> render_info({:tap, :paste_code})

      assert text(view) =~ "Code received"
      assert_receive {:operator_login, :anthropic, :ok} = done, 2_000
      assert view |> render_info(done) |> text() =~ "Signed in to Claude (Anthropic)"
    end

    test "a sign-out the store refuses says so, and the sign-in stays", %{tmp_dir: dir} do
      :ok = Auth.put(:anthropic, @creds)
      FlakySecureStore.install([:delete])
      on_exit(&FlakySecureStore.restore/0)

      %{view: view} = mount_menu(dir, :accounts)

      view =
        view
        |> render_info({:tap, {:sign_out, :anthropic}})
        |> render_info({:tap, {:confirm_sign_out, :anthropic}})

      assert text(view) =~
               "Couldn't sign out of Claude (Anthropic) (:disk_full): it is still signed in."

      assert Auth.signed_in?(:anthropic)
    end

    test "a login QR from the Mac opens the scanner", %{tmp_dir: dir} do
      %{view: view} = mount_menu(dir, :accounts)
      assert text(view) =~ "mix operator.login"

      assert view |> render_info({:tap, :scan_qr}) |> navigated_to() ==
               Operator.LoginScanScreen
    end
  end

  describe "model" do
    test "lists the signed-in provider's models; picking one sets it and returns", %{
      tmp_dir: dir
    } do
      :ok = Auth.put(:anthropic, @creds)
      %{view: view, loop: loop} = mount_menu(dir, :model)
      assert_renderable(view)

      shown = text(view)
      assert shown =~ "Claude Sonnet"
      assert shown =~ ~r/● +Claude Haiku 4.5/
      # retired models aren't offered
      refute shown =~ "Claude Haiku 3"
      # ChatGPT isn't signed in: a hint, no Codex models
      assert shown =~ "sign in under accounts to add these"
      refute shown =~ "GPT-"

      opus = Enum.find(Models.catalog(:anthropic), &(&1.name =~ "Opus"))
      view = render_info(view, {:tap, {:pick_model, opus.spec}})
      assert nav(view) == {:pop_to, Operator.ChatScreen}
      assert Loop.snapshot(loop).model == opus.spec

      # the current one is marked
      view = mount_on(loop, dir, :model)
      assert text(view) =~ ~r/● +#{Regex.escape(opus.name)}/
    end

    test "a custom model, in omp's provider/model form too", %{tmp_dir: dir} do
      %{view: view, loop: loop} = mount_menu(dir, :model)

      view = render_info(view, {:tap, :save_model})
      assert text(view) =~ "Type a model first"

      view =
        view
        |> render_info({:change, :model_draft, "openai-codex/gpt-5-mini"})
        |> render_info({:tap, :save_model})

      assert nav(view) == {:pop_to, Operator.ChatScreen}
      assert Loop.snapshot(loop).model == "openai_codex:gpt-5-mini"
    end

    test "not while the agent runs", %{tmp_dir: dir} do
      %{view: view, loop: loop} = mount_menu(dir, :model, [[{:text, "x"}, :block]])
      :ok = Loop.prompt(loop, "go")
      await_event(:message_update)

      view = render_info(view, {:tap, {:pick_model, "anthropic:claude-sonnet-4-5"}})
      assert text(view) =~ "Can't change the model while the agent runs."
      assert nav(view) == nil
      Loop.stop(loop)
    end

    test "the chat's session gone (another session shown, or its loop died): a note, no crash",
         %{tmp_dir: dir} do
      %{view: view, loop: loop} = mount_menu(dir, :model)
      ref = Process.monitor(loop)
      Process.exit(loop, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      view = render_info(view, {:tap, {:pick_model, "anthropic:claude-sonnet-4-5"}})

      assert text(view) =~
               "That session isn't running any more: start a new session or resume one."

      assert nav(view) == nil
    end
  end

  describe "sessions" do
    defp saved(dir, title) do
      s = Session.new(dir, model(), dir)
      {s, _} = Session.append(%{s | title: title}, Session.user("hi"))
      s.path
    end

    test "the saved sessions, newest first, the shown one marked; tapping one resumes it", %{
      tmp_dir: dir
    } do
      older = saved(dir, "Older work")
      File.touch!(older, System.os_time(:second) - 3 * 86_400)
      %{loop: loop} = start_loop(dir, [[{:text, "ok"}]])
      :ok = Loop.prompt(loop, "Current work")
      await_event(:agent_end)
      view = mount_on(loop, dir, :sessions)

      assert_renderable(view)
      shown = text(view)
      assert shown =~ ~r/● +Current work/
      assert shown =~ "  Older work"
      assert shown =~ "3d ago"
      assert :binary.match(shown, "Current work") < :binary.match(shown, "Older work")

      assert view |> render_info({:tap, {:resume, older}}) |> nav() ==
               {:pop_to, Operator.ChatScreen}

      assert_received {:operator_menu, {:resume, ^older}}

      # the one shown: just back to it
      current = Loop.snapshot(loop).path

      assert view |> render_info({:tap, {:resume, current}}) |> nav() ==
               {:pop_to, Operator.ChatScreen}

      refute_received {:operator_menu, {:resume, _}}

      assert view |> render_info({:tap, :new_session}) |> nav() == {:pop_to, Operator.ChatScreen}
      assert_received {:operator_menu, :new_session}
    end

    test "a session with no prompt yet (only a model change) shows as untitled", %{tmp_dir: dir} do
      s = Session.new(dir, model(), dir)
      Session.append(s, Session.model_change("anthropic:claude-sonnet-4-5"))
      %{view: view} = mount_menu(dir, :sessions)
      assert text(view) =~ "  (untitled)"
    end

    test "none saved yet", %{tmp_dir: dir} do
      %{view: view} = mount_menu(dir, :sessions)
      assert text(view) =~ "no saved sessions yet"
    end
  end
end
