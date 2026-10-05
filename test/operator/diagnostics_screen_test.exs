defmodule Operator.DiagnosticsScreenTest do
  use Mob.ScreenCase, async: false

  alias Operator.Core.Budget
  alias Operator.Core.Settings
  alias Operator.DiagnosticsScreen

  test "mounts and renders a terminal page the native layer can draw; back pops" do
    view = mount_screen(DiagnosticsScreen)
    assert_renderable(view)
    assert text(view) =~ "[frontend]"
    assert text(view) =~ "menu › diagnostics"
    assert text(view) =~ "dyn layer"
    assert view |> render_info({:tap, :back}) |> navigated_to() == {:pop}
  end

  test "Scan QR opens the scanner; rescue opens the rescue screen" do
    view = mount_screen(DiagnosticsScreen)
    assert view |> render_info({:tap, :scan_qr}) |> navigated_to() == Operator.LoginScanScreen
    assert view |> render_info({:tap, :rescue}) |> navigated_to() == Operator.RescueScreen
  end

  test "a link scanned with another app goes to the chat" do
    view = mount_screen(DiagnosticsScreen)
    link = "operator://elsewhere"
    view = render_info(view, {:link, %{url: link, source: :running}})
    assert {:reset, Operator.ChatScreen, %{link: ^link}, _} = view.socket.__mob__.nav_action
  end

  @tag :tmp_dir
  test "shows today's spend against the cap; the cap can be changed", %{tmp_dir: dir} do
    :ok = Budget.record(dir, 0.1234)
    view = mount_screen(DiagnosticsScreen, %{data_dir: dir})
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
  test "code updates: the server, the code running, and check for updates now" do
    view = mount_screen(DiagnosticsScreen)
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
