defmodule Operator.HomeScreenTest do
  # async: false: the key store and the OAuth server are app-wide singletons.
  use Mob.ScreenCase, async: false

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
end
