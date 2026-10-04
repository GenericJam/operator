defmodule Operator.RescueScreenTest do
  # Dyn generations load into the VM-wide code server.
  use Mob.ScreenCase, async: false

  import Operator.Test.Dyn

  alias Operator.Core.ApproveButton
  alias Operator.Core.Dyn
  alias Operator.RescueScreen

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    Application.put_env(:operator, :chat_native, Operator.Test.FakeNative)

    on_exit(fn ->
      purge_all()
      Application.delete_env(:operator, :chat_native)
    end)
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
    assert find(view, :button, text: "Approve revert to G0")
    assert Dyn.status().generation == n

    view = render_info(view, {:approval, "approved", %{"subject" => {:revert_to, 0}}})
    assert_received {:confirmed, {:revert_to, 0}}
    assert_renderable(view)
    assert text(view) =~ "Generation 0 is current."
    assert text(view) =~ "Running G0"
    assert Dyn.status().generation == 0
    assert text(view) =~ "reverted by hand to generation 0"
    refute find(view, :button, text: "Approve revert to G0")
  end

  test "a cancelled prompt or no screen lock reverts nothing; cancel hides the approve",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")}, "Add a weather tool")
    view = mount_screen(RescueScreen) |> render_info({:tap, {:revert, 0}})
    subject = {:revert_to, 0}

    view =
      render_info(view, {:approval, "failed", %{"reason" => "lockout", "subject" => subject}})

    assert text(view) =~ "Not reverted: too many wrong tries"

    view = render_info(view, {:approval, "unavailable", %{"subject" => subject}})
    assert text(view) =~ ApproveButton.why("unavailable", %{})
    assert Dyn.status().generation == n

    view = render_info(view, {:tap, :cancel_revert})
    refute find(view, :button, text: "Approve revert to G0")
    assert find(view, :button, text: "Revert to this")
  end

  test "with the production approval the plain button reverts nothing", %{tmp_dir: dir} do
    start_supervised!(Operator.Core.Dyn.Approval.Biometric)
    start_keeper(dir, approval: Operator.Core.Dyn.Approval.Biometric)
    :ok = Dyn.stage_put("weather.ex", tool("Weather", "weather"))
    {:ok, %{n: n}} = Dyn.propose("weather")

    view = mount_screen(RescueScreen)
    assert text(view) =~ "G#{n} · candidate"

    view = view |> render_info({:tap, {:revert, 0}}) |> render_info({:tap, :approve_revert})
    assert text(view) =~ "Not reverted: it needs approving"
    assert Dyn.status().generation == 0
  end
end
