defmodule Operator.HomeScreenTest do
  # async: false: the sign-ins (Operator.Auth) are app-wide.
  use Mob.ScreenCase, async: false

  alias Operator.Auth
  alias Operator.Core.Budget
  alias Operator.Core.Settings
  alias Operator.HomeScreen

  setup do
    start_supervised!(Auth)
    on_exit(fn -> for p <- Auth.providers(), do: Operator.SecureStore.delete("auth:#{p}") end)
  end

  defp creds(email),
    do: %{
      "type" => "oauth",
      "access" => "at",
      "refresh" => "rt",
      "expires" => System.os_time(:millisecond) + 90 * 60_000,
      "email" => email
    }

  test "mounts and renders a tree the native layer can draw" do
    view = mount_screen(HomeScreen)
    assert_renderable(view)
    assert text(view) =~ "Claude (Anthropic): not signed in"
    assert text(view) =~ "/login anthropic"
  end

  test "the first sign-in hands over to the chat; later changes only update the status" do
    view = mount_screen(HomeScreen)

    :ok = Auth.put(:openai_codex, creds("k@example.com"))
    assert_receive {:operator_auth, :changed} = msg
    view = render_info(view, msg)
    assert navigated_to(view) == Operator.ChatScreen
    assert text(view) =~ "ChatGPT (OpenAI Codex): signed in as k@example.com · token good for 1 h"

    view = mount_screen(HomeScreen)
    :ok = Auth.put(:anthropic, creds(nil))
    assert_receive {:operator_auth, :changed} = msg
    view = render_info(view, msg)
    assert navigated_to(view) == nil
    assert text(view) =~ "Claude (Anthropic): signed in · token"
  end

  test "Scan QR opens the scanner" do
    view = mount_screen(HomeScreen)
    assert view |> render_info({:tap, :scan_qr}) |> navigated_to() == Operator.LoginScanScreen
  end

  @tag :tmp_dir
  test "shows today's spend against the cap; the cap can be changed", %{tmp_dir: dir} do
    :ok = Budget.record(dir, 0.1234)
    view = mount_screen(HomeScreen, %{data_dir: dir})
    assert text(view) =~ "Today $0.1234 of the $1.00 daily cap"

    view =
      view
      |> render_info({:change, :cap, " 2.5 "})
      |> render_info({:tap, :save_cap})

    assert text(view) =~ "Today $0.1234 of the $2.50 daily cap"
    assert Settings.daily_cap(dir) == 2.5

    view = view |> render_info({:change, :cap, "lots"}) |> render_info({:tap, :save_cap})
    assert text(view) =~ "Not a dollar amount: lots"
    assert Settings.daily_cap(dir) == 2.5
  end

  @tag :capture_log
  test "code updates: the server, the code running, and Check for updates now" do
    view = mount_screen(HomeScreen)
    assert_receive {:operator_deliver, :status, _status} = status, 2_000
    view = render_info(view, status)
    assert_renderable(view)
    assert text(view) =~ "Update server: not set"
    assert text(view) =~ "Running: this build's own code"

    view = render_info(view, {:tap, :check_updates})
    assert text(view) =~ "Checking for updates"
    # No update server on this host: the check says so instead of fetching.
    assert_receive {:operator_deliver, :checked, {:error, :not_configured}} = checked, 2_000
    view = render_info(view, checked)
    assert text(view) =~ "This check: no update server set"
  end
end
