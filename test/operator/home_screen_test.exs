defmodule Operator.HomeScreenTest do
  # async: false: the key store and the OAuth server are app-wide singletons.
  use Mob.ScreenCase, async: false

  alias Operator.Core.Budget
  alias Operator.Core.Settings
  alias Operator.HomeScreen

  setup do
    on_exit(fn -> Operator.KeyStore.delete() end)
  end

  test "mounts and renders a tree the native layer can draw" do
    start_supervised!({Operator.OpenRouter.OAuth, []})
    view = mount_screen(HomeScreen)
    assert_renderable(view)
  end

  test "once signed in it hands over to the chat" do
    start_supervised!({Operator.OpenRouter.OAuth, []})
    view = mount_screen(HomeScreen)
    assert view |> render_info({:oauth, :awaiting_browser}) |> navigated_to() == nil

    :ok = Operator.KeyStore.put("sk-test-not-a-real-key")
    stop_supervised!(Operator.OpenRouter.OAuth)
    start_supervised!({Operator.OpenRouter.OAuth, []})
    assert view |> render_info({:oauth, :signed_in}) |> navigated_to() == Operator.ChatScreen
  end

  @tag :tmp_dir
  test "shows today's spend against the cap; the cap can be changed", %{tmp_dir: dir} do
    start_supervised!({Operator.OpenRouter.OAuth, []})
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
end
