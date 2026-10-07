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

  defp install(keeper \\ Dyn.Keeper, sources \\ Seed.sources()) do
    test = self()
    assert {:ok, pid} = Seed.start(keeper, fn -> send(test, :seed_done) end, sources)
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

    # Once per seed: the same seed again changes nothing.
    assert Seed.start() == :ignore
    assert Seed.needed(Path.join(dir, "dyn")) == :none

    assert Dyn.seed(&Seed.merge(&1, Seed.digests(), Seed.sources()), Seed.rationale()) ==
             {:error, :no_changes}

    # The front switches to the default front's start screen, the welcome.
    assert_receive {:operator_front, %{view: {:tree, tree}}}, 5_000
    assert Mob.ScreenCase.text(tree) =~ "This is the front"
    assert %{stack: ["WelcomeScreen"], view: :running} = Front.status()
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
    assert Dyn.seed(&Map.merge(&1, Seed.sources()), Seed.rationale()) == {:error, :safe_mode}

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

  describe "a newer seed on a phone that has one" do
    @old %{
      "front.ex" => """
      defmodule Operator.Dyn.Front do
        def start, do: Operator.Dyn.Old
      end
      """,
      "old.ex" => screen("Old", "old start"),
      "kept.ex" => screen("Kept", "kept v1"),
      "edited.ex" => screen("Edited", "edited v1"),
      "dropped.ex" => screen("Dropped", "dropped v1")
    }

    @new %{
      "front.ex" => """
      defmodule Operator.Dyn.Front do
        def start, do: Operator.Dyn.Welcome
      end
      """,
      "old.ex" => screen("Old", "old start"),
      "welcome.ex" => screen("Welcome", "welcome"),
      "kept.ex" => screen("Kept", "kept v2"),
      "edited.ex" => screen("Edited", "edited v2"),
      "added.ex" => screen("Added", "added v2")
    }

    test "replaces only the seed files nobody changed, and isn't retried", %{tmp_dir: dir} do
      dyn = Path.join(dir, "dyn")
      start_keeper(dyn)
      install(Dyn.Keeper, @old)
      first = Store.seed(dyn)

      # The user's changes: an edited seed file, a screen of their own.
      mine = screen("Mine", "mine")
      edited = screen("Edited", "edited by the user")
      n = activate!(Map.merge(Dyn.staged(), %{"edited.ex" => edited, "mine.ex" => mine}))
      assert {:update, _} = Seed.needed(dyn, digests(@new))

      install(Dyn.Keeper, @new)
      sources = Dyn.sources(Store.seed(dyn))
      assert Store.seed(dyn) > n and Store.seed(dyn) != first

      # Unchanged seed files take the new seed's; a dropped one goes.
      assert sources["kept.ex"] == @new["kept.ex"]
      assert sources["front.ex"] == @new["front.ex"]
      assert sources["added.ex"] == @new["added.ex"]
      refute Map.has_key?(sources, "dropped.ex")
      # The user's edit and their own screen stay exactly as they were.
      assert sources["edited.ex"] == edited
      assert sources["mine.ex"] == mine
      assert %{pending: nil} = Dyn.status()

      # Recorded as the new seed: not installed again.
      assert Seed.needed(dyn, digests(@new)) == :none
      assert Seed.start(Dyn.Keeper, fn -> :ok end, @new) == :ignore
    end

    test "a merge that breaks keeps what runs, and isn't retried", %{tmp_dir: dir} do
      dyn = Path.join(dir, "dyn")
      start_keeper(dyn)
      # The installed seed's Kept has a struct; the new seed's doesn't.
      kept = """
      defmodule Operator.Dyn.Kept do
        defstruct [:a]
      end
      """

      install(Dyn.Keeper, Map.put(@old, "kept.ex", kept))

      # The user's code relies on it (Kept itself is unchanged, so the new
      # seed would replace it).
      uses = """
      defmodule Operator.Dyn.Uses do
        def value, do: %Operator.Dyn.Kept{a: 1}
      end
      """

      n = activate!(Map.put(Dyn.staged(), "uses.ex", uses))
      install(Dyn.Keeper, @new)

      # Nothing changed, and that seed isn't tried again.
      assert %{generation: ^n, pending: nil} = Dyn.status()
      assert Dyn.sources(n)["kept.ex"] == kept
      assert Seed.needed(dyn, digests(@new)) == :none
      assert Seed.start(Dyn.Keeper, fn -> :ok end, @new) == :ignore
    end

    test "an install that recorded nothing uses its seed generation's sources",
         %{tmp_dir: dir} do
      dyn = Path.join(dir, "dyn")
      start_keeper(dyn)
      install(Dyn.Keeper, @old)
      # As an older app left it: the seed's generation, no record of its files.
      File.rm!(Path.join(dyn, "seed.json"))
      assert {:update, shipped} = Seed.needed(dyn, digests(@new))
      assert shipped == digests(@old)
    end
  end

  defp digests(sources),
    do:
      Map.new(sources, fn {p, s} ->
        {p, :sha256 |> :crypto.hash(s) |> Base.encode16(case: :lower)}
      end)

  describe "merge/3" do
    test "keeps user edits, deletions and files; takes unchanged and new seed files" do
      shipped = digests(%{"a.ex" => "a1", "b.ex" => "b1", "c.ex" => "c1", "d.ex" => "d1"})

      current = %{
        "a.ex" => "a1",
        "b.ex" => "b edited",
        "d.ex" => "d1",
        "mine.ex" => "m",
        "n.ex" => "mine"
      }

      seed = %{"a.ex" => "a2", "b.ex" => "b2", "c.ex" => "c2", "n.ex" => "new", "e.ex" => "e2"}

      assert Seed.merge(current, shipped, seed) == %{
               # unchanged: updated
               "a.ex" => "a2",
               # edited: the user's
               "b.ex" => "b edited",
               # c.ex deleted by the user: stays deleted; d.ex dropped by the seed: gone
               "mine.ex" => "m",
               # a user file where the seed now has one: the user's
               "n.ex" => "mine",
               # new in the seed
               "e.ex" => "e2"
             }
    end

    test "a first install puts the seed under what's there" do
      assert Seed.merge(%{"a.ex" => "mine"}, %{}, %{"a.ex" => "seed", "b.ex" => "seed"}) ==
               %{"a.ex" => "mine", "b.ex" => "seed"}
    end
  end
end
