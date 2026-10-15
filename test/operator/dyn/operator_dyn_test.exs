defmodule Operator.DynTest do
  @moduledoc """
  Operator's side of the Dyn layer (rho's `Rho.Dyn`, tested in rho): its
  check limits (config :rho, :dyn), its samples and seed, Ash in front
  screens.
  """
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn.Samples
  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Front
  alias Rho.Dyn
  alias Rho.Dyn.Check
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Store

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
    # The seed's theme chips read and write Mob.State.
    if Process.whereis(Mob.State) == nil, do: start_supervised!(Mob.State)
    :ok
  end

  defp probe(body) do
    """
    defmodule Operator.Dyn.Probe do
      def go(pid, mod, fun, ctx) do
        _ = {pid, mod, fun, ctx}
        #{body}
      end
    end
    """
  end

  # The violations `body` causes, as "line: message" lines.
  defp violation(body) do
    assert {:error, violations} = Check.run(%{"probe.ex" => probe(body)})
    Enum.map_join(violations, "\n", &"#{&1.line}: #{&1.message}")
  end

  test "Dyn code keeps out of the sign-ins and Operator's own code, and Files' roots" do
    banned = [
      {":operator_secure_store.get(\"auth:anthropic\")", "sign-ins"},
      {"Operator.SecureStore.get(\"auth:anthropic\")", "Core's own code"},
      {"Operator.Core.Settings.put_voice(:off)", "Core's own code"},
      {"Rho.Auth.status()", "Core's own code"},
      {~s|File.read("/data/secure/auth_anthropic")|, "use Operator.Core.Files"},
      # Files' file-tool side takes a caller's roots: a forged ctx escapes them.
      {~s|Operator.Core.Files.workspace(%{data_dir: "/data"})|,
       "Operator.Core.Files.workspace/1, which Dyn code may not"},
      {~s|Operator.Core.Files.resolve("x", :write, ctx)|,
       "Operator.Core.Files.resolve/3, which Dyn code may not"},
      {"Operator.Core.Files.roots(ctx)", "Operator.Core.Files.roots/1, which Dyn code may not"},
      {~s|Operator.Core.Files.real_path("/data")|, "Operator.Core.Files.real_path/1"},
      {"Operator.Core.Files.needs_access?(\"/x\")", "Operator.Core.Files.needs_access?/1"},
      {"Operator.Core.Files.grant_capability({:files, :picked, []})",
       "Operator.Core.Files.grant_capability/1"}
    ]

    for {body, expected} <- banned do
      assert violation(body) =~ ~r/^4: .*#{Regex.escape(expected)}/, "#{body} was not rejected"
    end

    allowed = """
    :ok = Operator.Core.Files.write(Path.join("notes", "today.txt"), "hi")
    {:ok, model} = Operator.Core.Files.read("models/tiny.tflite")
    {:ok, handle, _delegate} = Operator.Core.Tflite.load(model)
    _ = NxTfliteMob.call(handle, [<<0::32>>])
    Operator.Core.Terminal.open()
    """

    assert {:ok, _} = Check.run(%{"probe.ex" => probe(allowed)})
  end

  test "the bundled sample screens pass the whole pipeline", %{tmp_dir: dir} do
    start_keeper(dir)
    files = Map.new(Samples.names(), &Samples.get/1)

    %{selftests: tests, warnings: []} = propose!(files, "samples")

    assert Enum.map(tests, &{&1.module, &1.kind, &1.ok}) == [
             {"Operator.Dyn.Checklist", :screen, true},
             {"Operator.Dyn.Hello", :screen, true}
           ]
  end

  test "an Ash resource (a struct with an Ecto schema's metadata and an Inspect implementation) proposes",
       %{tmp_dir: dir} do
    start_keeper(dir)

    resource = """
    defmodule Operator.Dyn.Things.Thing do
      use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end

      actions do
        defaults [:read, create: :*]
      end
    end
    """

    assert %{n: n, modules: modules} = propose!(%{"things/thing.ex" => resource})
    names = Enum.map(modules, & &1.module)
    assert "Operator.Dyn.Things.Thing" in names
    assert "Inspect.Operator.Dyn.Things.Thing" in names

    assert Module.concat(Inspect, Module.concat(["Operator.Dyn.G#{n}.Things.Thing"])) in Compiler.loaded(
             n
           )
  end

  defp install do
    test = self()
    assert {:ok, pid} = Seed.start(notify: fn -> send(test, :seed_done) end)
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

    assert Rho.Dyn.Seed.needed(
             Path.join(dir, "dyn"),
             Rho.Dyn.Seed.digests(Seed.sources()),
             Seed.legacy_digests()
           ) == :none

    # The front switches to the default front's start screen, the welcome.
    assert_receive {:operator_front, %{view: {:tree, tree}}}, 5_000
    assert Mob.ScreenCase.text(tree) =~ "This is the front"
    assert %{stack: ["WelcomeScreen"], view: :running} = Front.status()
    assert Front.toggle() == :dial
  end
end
