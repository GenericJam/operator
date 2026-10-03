defmodule Operator.Core.KeepAliveTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers, only: [collect: 0]
  import Operator.Test.ObserverHelpers

  alias Operator.Core.Current
  alias Operator.Core.KeepAlive
  alias Operator.Core.Loop
  alias Operator.Test.FakeKeepAlive

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp start(dir, script, opts \\ []) do
    %{current: current} = start_current(dir, script)

    ka =
      start_observer(
        KeepAlive,
        current,
        Keyword.merge([backend: {FakeKeepAlive, self()}, grace_ms: 200], opts)
      )

    %{current: current, ka: ka}
  end

  defp run(loop, text) do
    :ok = Loop.subscribe(loop)
    :ok = Loop.prompt(loop, text)
    collect()
  end

  test "on at a run's start, off a grace period after its end", %{tmp_dir: dir} do
    %{current: current, ka: ka} = start(dir, [[{:text, "hi"}]])
    loop = Current.current(current)

    run(loop, "go")
    assert_receive {:keep_alive, :on}
    refute_receive {:keep_alive, _}, 100
    assert_receive {:keep_alive, :off}, 500
    assert KeepAlive.status(ka) == %{on: false, running: []}
  end

  test "a run starting within the grace period keeps it on: no off/on flap", %{tmp_dir: dir} do
    %{current: current} = start(dir, [[{:text, "one"}], [{:text, "two"}]])
    loop = Current.current(current)

    run(loop, "first")
    run(loop, "second")
    assert_receive {:keep_alive, :on}
    assert_receive {:keep_alive, :off}, 500
    refute_receive {:keep_alive, _}, 100
  end

  test "a new session: the old loop's unfinished run ends, the new loop is watched", %{
    tmp_dir: dir
  } do
    %{current: current} = start(dir, [[{:sleep, 1_000}, {:text, "slow"}], [{:text, "new"}]])
    old = Current.current(current)
    :ok = Loop.prompt(old, "long job")
    assert_receive {:keep_alive, :on}

    new = Current.new_session(current)
    refute new == old
    assert_receive {:keep_alive, :off}, 500

    run(new, "next")
    assert_receive {:keep_alive, :on}
    assert_receive {:keep_alive, :off}, 500
  end

  test "a loop that dies mid-run counts as ended; its reopened loop is watched", %{
    tmp_dir: dir
  } do
    %{current: current} = start(dir, [[{:sleep, 1_000}, {:text, "lost"}], [{:text, "back"}]])
    loop = Current.current(current)
    :ok = Loop.prompt(loop, "long job")
    assert_receive {:keep_alive, :on}

    ref = Process.monitor(loop)
    Process.exit(loop, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert_receive {:keep_alive, :off}, 500

    reopened = Current.current(current)
    refute reopened == loop
    run(reopened, "again")
    assert_receive {:keep_alive, :on}
  end

  for mode <- [:error, :raise] do
    test "a failing backend (#{mode}) is retried at the next run, the observer lives", %{
      tmp_dir: dir
    } do
      %{current: current, ka: ka} =
        start(dir, [[{:text, "one"}], [{:text, "two"}]],
          backend: {FakeKeepAlive, {unquote(mode), self()}},
          grace_ms: 20
        )

      loop = Current.current(current)
      run(loop, "first")
      assert_receive {:keep_alive, :on}
      assert KeepAlive.status(ka).on == false
      refute_receive {:keep_alive, :off}, 100

      run(loop, "second")
      assert_receive {:keep_alive, :on}
    end
  end
end
