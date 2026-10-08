defmodule Operator.Core.Dyn.EngineTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Samples
  alias Operator.Core.Dyn.Store
  alias Operator.Core.ToolRegistry

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  defp counter(tag) do
    """
    defmodule Operator.Dyn.Counter do
      alias Operator.Dyn.Counter.Label

      def version, do: Label.tag()

      def wait do
        Process.sleep(200)
        {:done, version()}
      end
    end

    defmodule Operator.Dyn.Counter.Label do
      def tag, do: #{inspect(tag)}
    end
    """
  end

  test "two generations of the same logical module load side by side and both run",
       %{tmp_dir: dir} do
    start_keeper(dir)

    n1 = activate!(%{"counter.ex" => counter("one")})
    {:ok, g1} = Dyn.lookup({:module, "Counter"})
    assert g1 == Operator.Dyn.G1.Counter
    waiter = Task.async(fn -> g1.wait() end)

    n2 = activate!(%{"counter.ex" => counter("two")})
    {:ok, g2} = Dyn.lookup({:module, "Counter"})
    assert g2 == Operator.Dyn.G2.Counter
    assert {n1, n2} == {1, 2}

    # Each generation's references were rewritten to its own modules.
    assert g1.version() == "one"
    assert g2.version() == "two"

    # A process already executing generation 1 keeps that generation's code.
    assert Task.await(waiter) == {:done, "one"}
  end

  test "a failing, hanging or memory-hungry selftest rejects the generation and leaves the current one",
       %{tmp_dir: dir} do
    start_keeper(dir, selftest_timeout_ms: 300, selftest_max_heap_mb: 8)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})
    {:ok, current} = Dyn.lookup({:tool, "weather"})

    for {selftest, expected} <- [
          {"{:error, :nope}", ~r/selftest\/0 returned \{:error, :nope\}/},
          {~s|raise "boom"|, ~r/RuntimeError.*boom/},
          {"(Process.sleep(:infinity); :ok)", ~r/timed out after 300 ms/},
          {"(1..10_000_000 |> Enum.to_list() |> length(); :ok)", ~r/killed: used more than 8 MB/}
        ] do
      :ok = Dyn.stage_reset()
      :ok = Dyn.stage_put("weather.ex", tool("Weather", "weather", selftest: selftest))

      assert {:error, %{stage: :selftest, n: bad, reason: reason, selftests: [result]}} =
               Dyn.propose("break it")

      assert reason =~ expected
      assert %{module: "Operator.Dyn.Weather", kind: :tool, ok: false} = result
      assert Compiler.loaded(bad) == []
      assert {:ok, %{status: :rejected}} = Dyn.generation(bad)

      assert %{generation: ^n, pending: nil} = Dyn.status()
      assert Store.current(dir) == n
      assert Dyn.lookup({:tool, "weather"}) == {:ok, current}
    end
  end

  # Realistic screens (interpolation, brackets, ~MOB, compile-time attributes)
  # pass the static check and the compiled-code check.
  test "the bundled sample screens pass the whole pipeline", %{tmp_dir: dir} do
    start_keeper(dir)
    files = Map.new(Samples.names(), &Samples.get/1)

    %{selftests: tests, warnings: []} = propose!(files, "samples")

    assert Enum.map(tests, &{&1.module, &1.kind, &1.ok}) == [
             {"Operator.Dyn.Checklist", :screen, true},
             {"Operator.Dyn.Hello", :screen, true}
           ]
  end

  test "a static-check or compile failure is rejected with file and line", %{tmp_dir: dir} do
    start_keeper(dir)

    :ok =
      Dyn.stage_put(
        "evil.ex",
        "defmodule Operator.Dyn.Evil do\n  def x, do: System.halt()\nend\n"
      )

    assert {:error, %{stage: :check, n: nil, reason: "evil.ex:2: calls System.halt/0" <> _}} =
             Dyn.propose("halt")

    # nothing was allocated for it
    assert Enum.map(Dyn.generations(), & &1.n) == [0]

    :ok = Dyn.stage_delete("evil.ex")

    :ok =
      Dyn.stage_put(
        "broken.ex",
        "defmodule Operator.Dyn.Broken do\n  def x, do: %Operator.Dyn.Nope{}\nend\n"
      )

    assert {:error, %{stage: :compile, n: n, reason: reason}} = Dyn.propose("broken")
    assert reason =~ "broken.ex:2:"
    assert reason =~ "Operator.Dyn.G#{n}.Nope"
    assert Compiler.loaded(n) == []
  end

  test "the current generation's tools are the loop's tools; a revert takes them away",
       %{tmp_dir: dir} do
    start_supervised!(ToolRegistry)
    start_keeper(dir)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})

    assert {:ok, mod} = ToolRegistry.lookup("weather")
    assert Compiler.generation_of(mod) == n
    assert mod in ToolRegistry.list()
    assert Operator.Core.Tools.Notes in ToolRegistry.list()
    assert mod.run(%{}, %{}) == {:ok, "ran weather"}

    # A Core tool's name can't be taken.
    :ok = Dyn.stage_put("my_notes.ex", tool("MyNotes", "notes"))
    assert {:error, %{stage: :names, reason: reason}} = Dyn.propose("shadow notes")
    assert reason =~ "notes is a Core tool's name"

    {:ok, token} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, %{n: 0}} = Dyn.revert_to(0, token)
    assert ToolRegistry.lookup("weather") == :error
    refute mod in ToolRegistry.list()
  end

  test "screens must mount and render; a live screen's crash is reported", %{tmp_dir: dir} do
    start_keeper(dir)
    :ok = Dyn.subscribe()

    bad = """
    defmodule Operator.Dyn.Bad do
      use Mob.Screen
      def mount(_params, _session, socket), do: {:ok, socket}
      def render(_assigns), do: :nope
    end
    """

    :ok = Dyn.stage_put("bad.ex", bad)
    assert {:error, %{stage: :selftest, reason: reason}} = Dyn.propose("bad screen")
    assert reason =~ "render/1 must return a view tree"

    :ok = Dyn.stage_delete("bad.ex")
    n = activate!(%{"notes.ex" => screen("Notes", "hello")})
    {:ok, gen} = Dyn.generation(n)

    assert [%{kind: :screen, ok: true, detail: "screen: mounted and rendered 2 nodes"}] =
             gen.selftests

    assert [{"Notes", mod}] = Dyn.screens()

    # A screen process, as mob's router runs one: mount, then a crash.
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = mod.mount(%{}, %{}, Mob.Socket.new(mod))
        send(test, :mounted)
        receive do: (:crash -> exit(:boom))
      end)

    assert_receive :mounted
    send(pid, :crash)
    assert %{gen: ^n, module: "Operator.Dyn.Notes", kind: :crash} = await_dyn(:crash)
  end
end
