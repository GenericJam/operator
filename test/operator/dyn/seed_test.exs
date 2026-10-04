defmodule Operator.Core.Dyn.SeedTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Dyn.Store
  alias Operator.Core.Front

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
    # The seed's theme chips read and write Mob.State.
    if Process.whereis(Mob.State) == nil, do: start_supervised!(Mob.State)
    :ok
  end

  defp install(keeper \\ Dyn.Keeper) do
    test = self()
    assert {:ok, pid} = Seed.start(keeper, fn -> send(test, :seed_done) end)
    assert Seed.running?()
    ref = Process.monitor(pid)
    assert_receive :seed_done, 120_000
    assert_receive {:DOWN, ^ref, :process, _, _}
    refute Seed.running?()
  end

  # The real seed: about 3 s on a Mac (half a minute on a Moto G 2021).
  test "the seed is installed once without approval, as the default front",
       %{tmp_dir: dir} do
    start_keeper(Path.join(dir, "dyn"))
    files = %{"weather.ex" => tool("Weather", "weather"), "hello.ex" => screen("Hello", "hi")}
    Enum.each(files, fn {path, src} -> :ok = Dyn.stage_put(path, src) end)
    {:ok, %{n: before}} = Dyn.propose("weather and hello")
    # Not while a proposal waits for the human.
    assert Seed.start() == :ignore
    {:ok, token} = Dyn.request_approval({:activate, before})
    {:ok, _} = Dyn.activate(before, token)

    # The front shows what there was: its only screen.
    settings = Path.join(dir, "settings")
    File.mkdir_p!(settings)
    start_supervised!({Front, dir: settings})
    _ = Front.subscribe()

    _ =
      Front.show(%{
        platform: :android,
        safe_area: %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0},
        size_class: Mob.SizeClass.placeholder()
      })

    assert_receive {:operator_front, %{view: {:tree, _}}}, 5_000
    assert %{stack: ["Hello"]} = Front.status()

    install()
    # Without approval, but `before` is still on probation and the merged
    # generation runs its code: it stays on probation.
    assert %{generation: n, status: :probation, parent: ^before, pending: nil} = Dyn.status()
    assert Store.seed(Path.join(dir, "dyn")) == n
    # On top of what was there: the weather tool and the screen stay.
    assert [{"weather", _}] = Dyn.tools()
    screens = Dyn.screens() |> Enum.map(&elem(&1, 0))
    assert "Hello" in screens
    assert "Showcase.GalleryScreen" in screens
    assert "Showcase.Components.Slider" in screens

    assert length(screens) ==
             1 + Enum.count(Seed.sources(), fn {_, src} -> src =~ "use Mob.Screen" end)

    # Staging follows it, so the agent edits the seed's screens.
    assert Dyn.staged() == Store.sources(Path.join(dir, "dyn"), n)

    # Once per install.
    assert Seed.start() == :ignore
    assert Dyn.seed(Seed.sources(), Seed.rationale()) == {:error, :seeded}

    # The front switches to the default front's start screen, the gallery.
    assert_receive {:operator_front, %{view: {:tree, tree}}}, 5_000
    assert Mob.ScreenCase.text(tree) =~ "60 components"
    assert %{stack: ["Showcase.GalleryScreen"], view: :running} = Front.status()
    assert Front.toggle() == :dial
  end

  test "the seed waits for the launch's rebuild, and isn't installed in safe mode",
       %{tmp_dir: dir} do
    dyn = Path.join(dir, "dyn")
    start_keeper(dyn)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})

    # Proven (boot probation leaves it alone), and built by an older app.
    {:ok, _} =
      Store.update_generation(
        dyn,
        n,
        &%{&1 | runtime: "an older app", status: :proven, quiet: true, restarted: true}
      )

    # Two launches in a row that never got going: safe mode, no seed.
    relaunch(dyn)
    relaunch(dyn)
    assert %{mode: :safe} = Dyn.status()
    assert Seed.start() == :ignore
    assert Dyn.seed(Seed.sources(), Seed.rationale()) == {:error, :safe_mode}

    # A normal launch rebuilding its generation: the seed goes on top once it's back.
    :ok = Store.put_boot_markers(dyn, %{boot_attempts: 0, stable: true})
    assert %{rebuilding: true} = relaunch(dyn)
    # An edit the agent hasn't proposed yet survives the seed.
    note = tool("Note", "note")
    :ok = Dyn.stage_put("note.ex", note)
    install()
    assert %{"note.ex" => ^note, "weather.ex" => _} = Dyn.staged()
    # The rebuilt generation's code is new to this app, so it's on probation
    # again, and the seed on top of it doesn't prove it.
    assert %{generation: seed, parent: ^n, status: :probation} = Dyn.status()
    assert Store.seed(dyn) == seed
    assert [{"weather", _}] = Dyn.tools()
  end
end
