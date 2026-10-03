defmodule Operator.RescueScreenTest do
  # Dyn generations load into the VM-wide code server.
  use Mob.ScreenCase, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.RescueScreen

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  test "lists generations, shows a diff, reverts through approval", %{tmp_dir: dir} do
    start_keeper(dir)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")}, "Add a weather tool")

    view = mount_screen(RescueScreen)
    assert_renderable(view)
    assert text(view) =~ "G#{n} · probation · current"
    assert text(view) =~ "Add a weather tool"
    assert text(view) =~ "No crashes."

    view = render_info(view, {:tap, {:diff, n}})
    assert text(view) =~ "+++ b/weather.ex"
    assert text(view) =~ ~s|+  def name, do: "weather"|

    view = render_info(view, {:tap, {:revert, 0}})
    assert_renderable(view)
    assert text(view) =~ "Generation 0 is current."
    assert text(view) =~ "Running G0"
    assert Dyn.status().generation == 0
    assert text(view) =~ "reverted by hand to generation 0"
  end

  test "without a wired biometric prompt nothing is reverted", %{tmp_dir: dir} do
    start_keeper(dir, approval: Operator.Core.Dyn.Approval.Biometric)
    :ok = Dyn.stage_put("weather.ex", tool("Weather", "weather"))
    {:ok, %{n: n}} = Dyn.propose("weather")

    view = mount_screen(RescueScreen)
    assert text(view) =~ "G#{n} · candidate"

    view = render_info(view, {:tap, {:revert, 0}})
    assert text(view) =~ "needs approval"
    assert Dyn.status().generation == 0
  end
end
