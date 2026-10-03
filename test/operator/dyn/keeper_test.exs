defmodule Operator.Core.Dyn.KeeperTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Keeper
  alias Operator.Core.Dyn.Store
  alias Operator.Core.ToolRunner

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  defp tools do
    %{
      "boom.ex" => tool("Boom", "boom", run: ~s|raise "boom"|),
      "slow.ex" => tool("Slow", "slow", run: "(Process.sleep(:infinity); {:ok, 1})")
    }
  end

  # Runs a tool call the way the loop does; `:kill` kills it once it runs,
  # as the loop's timeout does.
  defp call_tool(name, how \\ :wait) do
    sup = start_supervised!(Task.Supervisor, id: make_ref())
    {:ok, mod} = Dyn.lookup({:tool, name})
    task = ToolRunner.start(sup, self(), mod, %{"arguments" => %{}}, &ToolRunner.allow_all/2, %{})
    assert_receive {:tool_running, pid}
    if how == :kill, do: Process.exit(pid, :kill)
    ref = task.ref
    assert_receive {:DOWN, ^ref, :process, _, reason}
    reason
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  # Activated, 60 s (here: probation_ms) without a crash, and a later launch
  # reached stable.
  defp prove!(dir, files, opts) do
    n = activate!(files)
    eventually(fn -> match?({:ok, %{quiet: true}}, Dyn.generation(n)) end)
    relaunch(dir, [stable: true] ++ opts)
    :ok = Dyn.subscribe()
    :ok = Keeper.mark_stable(Keeper)
    assert %{gen: ^n} = await_dyn(:proven)
    n
  end

  test "activation needs an approval for that very generation", %{tmp_dir: dir} do
    start_keeper(dir)
    %{n: n} = propose!(%{"weather.ex" => tool("Weather", "weather")})

    assert Dyn.activate(n, nil) == {:error, :approval_required}
    assert Dyn.activate(n, :forged) == {:error, :invalid_approval}
    {:ok, other} = Dyn.request_approval({:activate, n + 1})
    assert Dyn.activate(n, other) == {:error, :invalid_approval}

    assert %{generation: 0, pending: ^n} = Dyn.status()
    assert Store.current(dir) == 0
    assert Dyn.tools() == []
    assert {:ok, %{status: :candidate}} = Dyn.generation(n)
  end

  test "the production approval refuses until the biometric prompt is wired", %{tmp_dir: dir} do
    start_keeper(dir, approval: Operator.Core.Dyn.Approval.Biometric)
    %{n: n} = propose!(%{"weather.ex" => tool("Weather", "weather")})

    assert Dyn.request_approval({:activate, n}) == {:error, :approval_required}
    assert Dyn.activate(n, {:test_approval, {:activate, n}}) == {:error, :approval_required}
    assert Store.current(dir) == 0
  end

  test "activation flips pointer and registry together; a failed pointer write changes neither",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather")})
    {:ok, g1} = Dyn.lookup({:tool, "weather"})
    %{n: n2} = propose!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})
    {:ok, token} = Dyn.request_approval({:activate, n2})

    # The temp file the pointer is written through can't be created: as if
    # the write died half way.
    File.mkdir_p!(Path.join(dir, "current.tmp"))
    assert {:error, {:pointer_not_written, _}} = Dyn.activate(n2, token)
    assert Store.current(dir) == n1
    assert Dyn.lookup({:tool, "weather"}) == {:ok, g1}
    assert %{generation: ^n1} = Dyn.status()
    assert {:ok, %{status: :candidate}} = Dyn.generation(n2)

    File.rm_rf!(Path.join(dir, "current.tmp"))
    assert {:ok, %{status: :probation, parent: ^n1}} = Dyn.activate(n2, token)
    assert Store.current(dir) == n2
    {:ok, g2} = Dyn.lookup({:tool, "weather"})
    assert g2.run(%{}, %{}) == {:ok, "v2"}
  end

  test "only the latest proposal, built on the current generation, can be activated",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"a.ex" => tool("A", "a")})

    # A newer proposal supersedes the pending one (and unloads it).
    %{n: old} = propose!(%{"b.ex" => tool("B", "b")})
    %{n: stale} = propose!(%{"c.ex" => tool("C", "c")})
    {:ok, token} = Dyn.request_approval({:activate, old})
    assert {:error, {:not_a_candidate, :superseded}} = Dyn.activate(old, token)
    assert Compiler.loaded(old) == []

    # The generation it was built on is no longer current.
    {:ok, back} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, _} = Dyn.revert_to(0, back)
    {:ok, token} = Dyn.request_approval({:activate, stale})
    assert {:error, {:stale, %{parent: ^n1, current: 0}}} = Dyn.activate(stale, token)
    assert Store.current(dir) == 0
  end

  test "3 crashes in 60 s on probation revert to the parent and report them", %{tmp_dir: dir} do
    start_keeper(dir)
    n = activate!(tools())
    :ok = Dyn.subscribe()

    assert {%RuntimeError{message: "boom"}, _} = call_tool("boom")

    assert %{gen: ^n, module: "Operator.Dyn.Boom", kind: :crash, status: :probation} =
             await_dyn(:crash)

    call_tool("boom")
    await_dyn(:crash)
    assert %{generation: ^n, status: :probation} = Dyn.status()

    assert call_tool("slow", :kill) == :killed
    assert %{kind: :killed, module: "Operator.Dyn.Slow"} = await_dyn(:crash)

    assert %{from: ^n, to: 0, reason: reason, crashes: crashes} = await_dyn(:reverted)
    assert reason =~ "3 crashes within 60 s"
    assert Enum.map(crashes, & &1.kind) == [:crash, :crash, :killed]

    assert %{generation: 0} = Dyn.status()
    assert Store.current(dir) == 0
    assert Dyn.tools() == []
    assert {:ok, %{status: :reverted}} = Dyn.generation(n)

    # The agent can read it all back later.
    assert ["crash", "crash", "crash", "reverted"] = Enum.map(Dyn.log(), & &1.type)
  end

  test "a proven generation is not reverted by crashes; they're reported", %{tmp_dir: dir} do
    start_keeper(dir, probation_ms: 30)
    n = prove!(dir, tools(), probation_ms: 30)

    for _ <- 1..3 do
      call_tool("boom")
      assert %{gen: ^n, status: :proven} = await_dyn(:crash)
    end

    refute_receive {:operator_dyn, %{type: :reverted}}, 100
    assert %{generation: ^n, status: :proven} = Dyn.status()
    assert Store.current(dir) == n
    assert {:ok, %{status: :proven}} = Dyn.generation(n)
  end

  test "boot probation reverts an unproven generation when the launch after it died",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v1"}|)})
    n2 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})

    # This launch reached stable; the next one runs generation 2 ...
    assert %{generation: ^n2, reverted: nil} = relaunch(dir, stable: true)
    {:ok, mod} = Dyn.lookup({:tool, "weather"})
    assert mod.run(%{}, %{}) == {:ok, "v2"}

    # ... and dies before reaching stable: the one after reverts first.
    assert %{generation: ^n1, reverted: %{from: ^n2, to: ^n1}, mode: :normal} = relaunch(dir)
    assert Store.current(dir) == n1
    {:ok, mod} = Dyn.lookup({:tool, "weather"})
    assert mod.run(%{}, %{}) == {:ok, "v1"}
    assert Compiler.loaded(n2) == []

    assert {:ok, %{status: :reverted, reason: "the launch after it was activated" <> _}} =
             Dyn.generation(n2)

    assert [%{type: "reverted", from: ^n2, to: ^n1}] = Dyn.log()
  end

  test "two launches in a row that never reach stable start the next in safe mode",
       %{tmp_dir: dir} do
    start_keeper(dir, probation_ms: 20)
    n = prove!(dir, %{"weather.ex" => tool("Weather", "weather")}, probation_ms: 20)

    assert %{mode: :normal, generation: ^n} = relaunch(dir)
    assert %{mode: :normal, generation: ^n, reverted: nil} = relaunch(dir)
    refute Dyn.safe_mode?()

    assert %{mode: :safe, generation: ^n, failed_launches: 2} = relaunch(dir)
    assert Dyn.safe_mode?()
    assert Dyn.tools() == []
    assert Compiler.loaded(n) == []
    assert %{mode: :safe, generation: ^n} = Dyn.status()
    assert Enum.any?(Dyn.log(), &(&1.type == "safe_mode"))

    # The safe launch got going: the next one loads the Dyn layer again.
    assert %{mode: :normal, generation: ^n} = relaunch(dir, stable: true)
    assert [{"weather", _}] = Dyn.tools()
  end

  test "an old generation is unloaded only once nothing runs its code", %{tmp_dir: dir} do
    start_keeper(dir)

    src = fn tag ->
      "defmodule Operator.Dyn.Waiter do\n  def wait do\n    receive do\n      :go -> #{inspect(tag)}\n    end\n  end\nend\n"
    end

    n1 = activate!(%{"waiter.ex" => src.("one")})
    {:ok, g1} = Dyn.lookup({:module, "Waiter"})
    waiter = Task.async(fn -> g1.wait() end)

    eventually(fn ->
      Process.info(waiter.pid, :current_function) == {:current_function, {g1, :wait, 0}}
    end)

    n2 = activate!(%{"waiter.ex" => src.("two")})
    n3 = activate!(%{"waiter.ex" => src.("three")})
    Process.sleep(150)
    assert Compiler.loaded(n1) == [g1]

    send(waiter.pid, :go)
    assert Task.await(waiter) == "one"
    eventually(fn -> Compiler.loaded(n1) == [] end)

    # The current generation and its parent (instant revert) stay.
    assert Compiler.loaded(n2) != []
    assert Compiler.loaded(n3) != []
  end
end
