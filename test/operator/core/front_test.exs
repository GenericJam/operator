# A plugin-like native view (a plugin's component isn't under Operator.).
defmodule FrontNativeGauge do
  use Mob.Component

  def mount(props, socket), do: {:ok, Mob.Socket.assign(socket, :level, props[:level])}
  # Its own state outlives the parent's re-renders.
  def update(_props, socket), do: {:ok, socket}
  def render(assigns), do: %{level: assigns.level}

  def handle_info({:level, level}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :level, level)}
end

defmodule Operator.Core.FrontTest do
  # Dyn generations load into the VM-wide code server; the shell screen runs
  # in the test process (Mob.ScreenCase).
  use Mob.ScreenCase, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.Core.Front
  alias Operator.Core.Front.Host
  alias Operator.Core.Phone
  alias Operator.Core.Settings
  alias Operator.Core.Terminal
  alias Operator.Core.ToolRunner
  alias Operator.Core.Tools.FrontOpen
  alias Operator.Core.Tools.FrontScreens
  alias Operator.Core.Tools.FrontScreenshot

  @moduletag :tmp_dir
  @moduletag :capture_log

  @env %{
    platform: :android,
    safe_area: %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0},
    size_class: Mob.SizeClass.placeholder()
  }

  defmodule LifecycleRoot do
    use Mob.Screen

    def mount(params, _session, socket), do: {:ok, Mob.Socket.assign(socket, params)}
    def render(_assigns), do: %{type: :text, props: %{text: "lifecycle root"}, children: []}

    def handle_info(:push, socket),
      do:
        {:noreply,
         Mob.Socket.push_screen(socket, Operator.Core.FrontTest.LifecycleChild, %{
           owner: socket.assigns.owner
         })}

    def handle_info(:boom, _socket), do: raise("lifecycle boom")
    def handle_info(_message, socket), do: {:noreply, socket}

    def terminate(reason, socket),
      do: send(socket.assigns.owner, {:terminated, :root, reason})
  end

  defmodule LifecycleChild do
    use Mob.Screen

    # Owns a task, as a page running inference does: only its owner may shut it down.
    def mount(params, _session, socket) do
      task = Task.async(fn -> Process.sleep(:infinity) end)
      send(params.owner, {:child_task, task.pid})
      {:ok, socket |> Mob.Socket.assign(params) |> Mob.Socket.assign(:task, task)}
    end

    def render(_assigns), do: %{type: :text, props: %{text: "lifecycle child"}, children: []}
    def handle_info(:pop, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
    def handle_info(_message, socket), do: {:noreply, socket}

    def terminate(reason, socket) do
      Task.shutdown(socket.assigns.task, :brutal_kill)
      send(socket.assigns.owner, {:terminated, :child, reason})
    end
  end

  defmodule NativeFront do
    use Mob.Screen

    def mount(params, _session, socket), do: {:ok, Mob.Socket.assign(socket, params)}

    def render(assigns) do
      # Claims to be a component the shell runs.
      forged =
        FrontNativeGauge
        |> Mob.UI.native_view(id: :borrowed, level: 9)
        |> Map.put(:__mob_expanded__, {assigns.shell, :borrowed, FrontNativeGauge, assigns.shell})

      kids =
        if assigns[:gauge] == false,
          do: [],
          else: [Mob.UI.native_view(FrontNativeGauge, id: :gauge, level: 3)]

      %{
        type: :column,
        props: %{},
        children:
          kids ++
            [Mob.UI.native_view(Operator.Core.ApproveButton, id: :approve, subject: :x), forged]
      }
    end

    def handle_info(:drop_gauge, socket), do: {:noreply, Mob.Socket.assign(socket, :gauge, false)}
    def handle_info(_message, socket), do: {:noreply, socket}
  end

  defmodule LifecycleHung do
    use Mob.Screen

    def mount(params, _session, socket), do: {:ok, Mob.Socket.assign(socket, params)}
    def render(_assigns), do: %{type: :text, props: %{text: "hung cleanup"}, children: []}
    def handle_info(_message, socket), do: {:noreply, socket}

    def terminate(_reason, socket) do
      send(socket.assigns.owner, :hung_cleanup_started)
      Process.sleep(:infinity)
    end
  end

  defmodule LifecycleFile do
    use Mob.Screen

    alias Operator.Core.Files

    def mount(params, _session, socket), do: {:ok, Mob.Socket.assign(socket, params)}
    def render(_assigns), do: %{type: :text, props: %{text: "file capability"}, children: []}

    def handle_info({:files, :picked, [%{path: path}]}, socket) do
      send(socket.assigns.owner, {:kept, Files.keep(path)})
      {:noreply, socket}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end

  setup %{tmp_dir: dir} do
    purge_all()
    on_exit(&purge_all/0)
    start_keeper(Path.join(dir, "dyn"))
    settings = Path.join(dir, "settings")
    File.mkdir_p!(settings)
    %{settings: settings}
  end

  defp home(text \\ "home") do
    """
    defmodule Operator.Dyn.Home do
      use Mob.Screen

      def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :taps, 0)}

      def render(assigns),
        do: %{type: :text, props: %{text: "#{text} \#{assigns.taps}"}, children: []}

      def handle_info({:tap, :count}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :taps, socket.assigns.taps + 1)}

      def handle_info({:tap, :next}, socket),
        do: {:noreply, Mob.Socket.push_screen(socket, Operator.Dyn.Second, %{n: 1})}

      def handle_info({:tap, :boom}, _socket), do: raise("boom from home")

      def handle_info({:tap, :escape}, socket),
        do: {:noreply, Mob.Socket.push_screen(socket, Operator.Dyn.Helpers)}

      def handle_info(_message, socket), do: {:noreply, socket}
    end
    """
  end

  @second """
  defmodule Operator.Dyn.Second do
    use Mob.Screen

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :n, Map.get(params, :n, 0))}

    def render(assigns), do: %{type: :text, props: %{text: "second \#{assigns.n}"}, children: []}

    def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

    def handle_info({:tap, :reset}, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, Operator.Dyn.Second, %{n: 9})}

    def handle_info(_message, socket), do: {:noreply, socket}
  end
  """

  @helpers """
  defmodule Operator.Dyn.Helpers do
    def hello, do: :hello
  end
  """

  defp settings(start, toggle) do
    """
    defmodule Operator.Dyn.Front do
      def start, do: #{start}
      def toggle, do: #{toggle}
    end
    """
  end

  defp files(extra \\ %{}) do
    Map.merge(
      %{
        "home.ex" => home(),
        "second.ex" => @second,
        "helpers.ex" => @helpers,
        "front.ex" => settings("Operator.Dyn.Home", ~s|{:text, " ☎ "}|)
      },
      extra
    )
  end

  defp start_front(settings) do
    start_supervised!({Front, dir: settings}, id: Front)
    :ok
  end

  # The next view whose text has `fragment` (earlier ones are skipped).
  defp await_view(fragment) do
    receive do
      {:operator_front, %{view: view} = snapshot} ->
        if view_text(view) =~ fragment, do: snapshot, else: await_view(fragment)
    after
      2_000 -> flunk("the front never showed #{inspect(fragment)}; #{inspect(Front.status())}")
    end
  end

  defp view_text({:tree, tree}), do: text(tree)
  defp view_text({kind, text}) when kind in [:error, :note], do: text

  defp tap_front(snapshot, tag), do: send(snapshot.host, {:tap, tag})

  test "only a native event carrying the host capability key grants a temporary file",
       %{tmp_dir: dir} do
    old_temp = Application.get_env(:operator, :app_temp)
    old_data = System.get_env("MOB_DATA_DIR")
    temp = Path.join(dir, "native-temp")
    File.mkdir_p!(temp)
    source = Path.join(temp, "picked.txt")
    File.write!(source, "picked")
    Application.put_env(:operator, :app_temp, temp)
    System.put_env("MOB_DATA_DIR", Path.join(dir, "data"))

    on_exit(fn ->
      if old_temp,
        do: Application.put_env(:operator, :app_temp, old_temp),
        else: Application.delete_env(:operator, :app_temp)

      if old_data,
        do: System.put_env("MOB_DATA_DIR", old_data),
        else: System.delete_env("MOB_DATA_DIR")
    end)

    event = {:files, :picked, [%{path: source}]}

    {host, _monitor, key} =
      Host.start(self(), [{LifecycleFile, %{owner: self()}}], @env, &(&1 == LifecycleFile))

    assert_receive {:operator_front_host, ^host, {:view, _}}
    send(host, event)
    assert_receive {:kept, {:error, refused}}, 1_000
    assert refused =~ "wasn't handed to this screen"

    # A forged wrapper stays opaque to the screen and grants nothing.
    send(host, {Host, :native, make_ref(), event})
    send(host, event)
    assert_receive {:kept, {:error, _}}, 1_000

    send(host, {Host, :native, key, event})
    assert_receive {:kept, {:ok, kept}}, 1_000
    assert File.read!(kept) == "picked"
    assert :ok = Host.stop(host)
  end

  test "the host tears down screens removed by navigation and orderly replacement" do
    allowed? = &(&1 in [LifecycleRoot, LifecycleChild])

    {host, monitor, _key} =
      Host.start(self(), [{LifecycleRoot, %{owner: self()}}], @env, allowed?)

    assert_receive {:operator_front_host, ^host, {:stack, [LifecycleRoot]}}
    assert_receive {:operator_front_host, ^host, {:view, _}}

    send(host, :push)
    assert_receive {:operator_front_host, ^host, {:stack, [LifecycleChild, LifecycleRoot]}}
    assert_receive {:child_task, task}
    assert_receive {:operator_front_host, ^host, {:view, _}}

    send(host, :pop)
    assert_receive {:terminated, :child, :normal}
    refute Process.alive?(task)
    assert_receive {:operator_front_host, ^host, {:stack, [LifecycleRoot]}}

    assert :ok = Host.stop(host)
    assert_receive {:terminated, :root, :shutdown}
    assert_receive {:DOWN, ^monitor, :process, ^host, :normal}
  end

  test "a front's native views run in components the host owns; Operator's own and forged ones don't" do
    env = %{@env | platform: :no_render}

    {host, _monitor, _key} =
      Host.start(self(), [{NativeFront, %{shell: self()}}], env, &(&1 == NativeFront))

    assert_receive {:operator_front_host, ^host, {:view, %{children: [gauge, approve, forged]}}}
    assert %{type: :native_view, props: %{module: "FrontNativeGauge", level: 3}} = gauge
    assert is_integer(gauge.props.component_handle)
    note = "(this native view can't run in the front)"
    assert %{type: :text, props: %{text: ^note}} = approve
    assert %{type: :text, props: %{text: ^note}} = forged

    # The component is the host's, not this (the shell's) process; its change repaints.
    {:ok, component} = Mob.ComponentRegistry.lookup(host, :gauge, FrontNativeGauge)
    assert {:error, :not_found} = Mob.ComponentRegistry.lookup(self(), :gauge, FrontNativeGauge)
    send(component, {:level, 7})

    assert_receive {:operator_front_host, ^host,
                    {:view, %{children: [%{props: %{level: 7}} | _]}}}

    # Leaving the view stops it; so does the host stopping.
    monitor = Process.monitor(component)
    send(host, :drop_gauge)
    assert_receive {:DOWN, ^monitor, :process, ^component, _}, 1_000
    assert :ok = Host.stop(host)
  end

  test "the host tears down its mounted screen when screen code crashes" do
    {host, monitor, _key} =
      Host.start(self(), [{LifecycleRoot, %{owner: self()}}], @env, &(&1 == LifecycleRoot))

    assert_receive {:operator_front_host, ^host, {:stack, [LifecycleRoot]}}
    assert_receive {:operator_front_host, ^host, {:view, _}}

    send(host, :boom)
    assert_receive {:terminated, :root, :shutdown}

    assert_receive {:DOWN, ^monitor, :process, ^host,
                    {%RuntimeError{message: "lifecycle boom"}, _}}
  end

  test "the host exits and cleans up when its owning Front process dies" do
    test = self()

    front =
      spawn(fn ->
        {host, _monitor, _key} =
          Host.start(self(), [{LifecycleRoot, %{owner: test}}], @env, &(&1 == LifecycleRoot))

        send(test, {:child_host, host})
        Process.sleep(:infinity)
      end)

    assert_receive {:child_host, host}
    monitor = Process.monitor(host)
    Process.exit(front, :kill)
    assert_receive {:terminated, :root, :shutdown}
    assert_receive {:DOWN, ^monitor, :process, ^host, :normal}
  end

  test "a hung screen cleanup is bounded and cannot hold the host open" do
    {host, monitor, _key} =
      Host.start(self(), [{LifecycleHung, %{owner: self()}}], @env, &(&1 == LifecycleHung))

    assert_receive {:operator_front_host, ^host, {:view, _}}
    started = System.monotonic_time(:millisecond)
    assert :ok = Host.stop(host)
    assert_receive :hung_cleanup_started
    assert System.monotonic_time(:millisecond) - started < 3_000
    # The watchdog killed the host: its cleanup can't keep it alive.
    assert_receive {:DOWN, ^monitor, :process, ^host, :killed}
  end

  test "the front opens its start screen and navigates within itself", %{settings: settings} do
    activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env)

    home = await_view("home 0")
    assert Front.toggle() == {:text, "☎"}
    assert %{stack: ["Home"], view: :running, visible: true} = Front.status()

    tap_front(home, :count)
    await_view("home 1")

    tap_front(home, :next)
    second = await_view("second 1")
    assert second.host == home.host
    assert %{stack: ["Second", "Home"]} = Front.status()
    assert Settings.front_stack(settings) == ["Second", "Home"]

    tap_front(second, :reset)
    await_view("second 9")
    assert %{stack: ["Second"]} = Front.status()

    # Popping the last screen does nothing: the front has no way out but the toggle.
    tap_front(second, :back)
    tap_front(second, :count)
    refute_receive {:operator_front, _}, 100
    assert %{stack: ["Second"]} = Front.status()
  end

  test "a front screen that raises shows its error; showing the front again retries it",
       %{settings: settings} do
    n = activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    home = Front.show(@env) && await_view("home 0")
    :ok = Dyn.subscribe()

    tap_front(home, :boom)
    crashed = await_view("boom from home")
    assert {:error, text} = crashed.view
    assert text =~ "Operator.Dyn.G#{n}.Home.handle_info/2"
    assert crashed.host == nil
    assert %{gen: ^n, module: "Operator.Dyn.Home"} = await_dyn(:crash)
    assert %{view: {:error, _}} = Front.status()

    # Off screen and on again: a new host, the screen as it starts.
    :ok = Front.hide()
    retried = Front.show(@env) && await_view("home 0")
    assert is_pid(retried.host) and retried.host != home.host

    # Opening a module that isn't a front screen is a crash of the screen too.
    tap_front(retried, :escape)
    assert {:error, text} = await_view("only open front screens").view
    assert text =~ "Operator.Dyn.G#{n}.Helpers"
  end

  test "restarting the front's host is not a crash; one host crash counts once",
       %{settings: settings} do
    n = activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env) && await_view("home 0")
    :ok = Dyn.subscribe()

    # Open restarts the host (kills the old one): never a crash, however often.
    for _ <- 1..3, do: {:ok, _} = Front.open("Home")
    refute_receive {:operator_dyn, %{type: :crash}}, 200
    assert %{generation: ^n, status: :probation} = Dyn.status()

    # The host mounts two more screens; its one crash is one crash.
    host = last_view()
    assert view_text(host.view) =~ "home 0"
    tap_front(host, :next)
    second = await_view("second 1")
    tap_front(second, :reset)
    second = await_view("second 9")
    Process.exit(second.host, :boom)
    assert %{gen: ^n} = await_dyn(:crash)
    refute_receive {:operator_dyn, %{type: :crash}}, 200
  end

  # The latest view once the front is quiet.
  defp last_view(last \\ nil) do
    receive do
      {:operator_front, snapshot} -> last_view(snapshot)
    after
      200 -> last || flunk("the front showed nothing")
    end
  end

  # Mob.ScreenCase may deliver an async front update while mounting or
  # rendering the shell. Read the server's current snapshot instead of
  # depending on whether the harness consumed that notification.
  defp shell_view(view, fragment) do
    snapshot = await_current_view(fragment)
    {render_info(view, {:operator_front, snapshot}), snapshot}
  end

  defp await_current_view(fragment, retries \\ 200)

  defp await_current_view(fragment, retries) when retries > 0 do
    snapshot = Front.subscribe()

    if view_text(snapshot.view) =~ fragment do
      snapshot
    else
      Process.sleep(10)
      await_current_view(fragment, retries - 1)
    end
  end

  defp await_current_view(fragment, 0),
    do: flunk("the front never showed #{inspect(fragment)}; #{inspect(Front.status())}")

  test "the shell draws the front under the toggle, forwards taps, and the toggle leaves",
       %{settings: settings} do
    activate!(files())
    start_front(settings)

    view = mount_screen(Operator.ShellScreen)
    assert Front.status().visible
    # The shell itself hears the host's first render; nothing else subscribed.
    assert_receive {:operator_front, %{view: {:tree, _}}}, 5_000
    {view, _home} = shell_view(view, "home 0")
    assert_renderable(view)
    assert text(view) =~ "home 0"
    assert_toggle(view)

    # Taps that aren't the shell's go to the front screen's process.
    _ = render_info(view, {:tap, :count})
    assert await_current_view("home 1").view |> view_text() =~ "home 1"

    view = render_info(view, {:tap, :operator_toggle})
    assert navigated_to(view) == {:pop}
    refute Front.status().visible
  end

  test "a crashed front screen leaves the shell drawing the error and the toggle",
       %{settings: settings} do
    activate!(files())
    start_front(settings)
    view = mount_screen(Operator.ShellScreen)
    {view, _home} = shell_view(view, "home 0")

    _ = render_info(view, {:tap, :boom})
    assert_receive {:operator_front, %{view: {:error, _}} = crashed}
    view = render_info(view, {:operator_front, crashed})
    assert_renderable(view)
    assert text(view) =~ "This front screen crashed."
    assert text(view) =~ "boom from home"
    assert_toggle(view)
    assert navigated_to(render_info(view, {:tap, :operator_toggle})) == {:pop}
  end

  # The toggle, drawn last (over the front), with its symbol, tappable.
  defp assert_toggle(view) do
    %{children: [_front, overlay]} = tree(view)
    assert find(overlay, :box, on_tap: {self(), :operator_toggle})
    assert text(overlay) == "☎"
  end

  @asker """
  defmodule Operator.Dyn.Asker do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :said, "asker")}
    def render(assigns), do: %{type: :text, props: %{text: assigns.said}, children: []}

    def handle_info({:tap, :ask}, socket) do
      result = Operator.Core.Terminal.draft("Use the Slider component in ")
      {:noreply, Mob.Socket.assign(socket, :said, "asked \#{inspect(result)}")}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end
  """

  test "the front screen on display may open the terminal with a draft; nothing else may",
       %{settings: settings} do
    activate!(files(%{"asker.ex" => @asker}))
    start_front(settings)
    _ = Front.subscribe()
    {:ok, _} = Front.open("Asker")
    # This process stands in for the chat (Operator.Core.Phone's host).
    :ok = Phone.register_host(self())

    view = mount_screen(Operator.ShellScreen)
    {view, asker} = shell_view(view, "asker")
    # Not from another process, like a Dyn tool or this test.
    assert Terminal.draft("x") == {:error, :not_in_front}

    _ = render_info(view, {:tap, :ask})
    await_current_view("asked :ok")
    assert_receive {:operator_front_terminal, "Use the Slider component in " = draft}

    view = render_info(view, {:operator_front_terminal, draft})
    assert navigated_to(view) == Operator.ChatScreen
    assert_receive {:operator_draft, ^draft}
    refute Front.status().visible

    # The front no longer shows: the same screen is refused.
    send(asker.host, {:tap, :ask})
    await_current_view("asked {:error, :not_in_front}")
  end

  test "open with push goes over the open screens, without repeating one",
       %{settings: settings} do
    activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("home 0")

    assert {:ok, "Second"} = Front.open("Second", push: true)
    await_view("second 0")
    assert %{stack: ["Second", "Home"]} = Front.status()

    assert {:ok, "Home"} = Front.open("Home", push: true)
    assert %{stack: ["Home", "Second"]} = Front.status()
    assert Settings.front_stack(settings) == ["Home", "Second"]
  end

  test "the open screens are reopened at the next launch; gone ones fall back to the start",
       %{settings: settings} do
    activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    home = Front.show(@env) && await_view("home 0")
    tap_front(home, :next)
    await_view("second 1")

    :ok = stop_supervised(Front)
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env)
    # Reopened without its params (a fresh mount), over the same stack.
    await_view("second 0")
    assert %{stack: ["Second", "Home"]} = Front.status()

    :ok = stop_supervised(Front)
    :ok = Settings.put_front_stack(["Gone", "AlsoGone"], settings)
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("home 0")
  end

  test "a new generation restarts the front on its new code", %{settings: settings} do
    activate!(files())
    start_front(settings)
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("home 0")

    activate!(%{"home.ex" => home("welcome")})
    await_view("welcome 0")
  end

  test "open takes a screen's name, its module name, or a unique last part",
       %{settings: settings} do
    card = fn mod -> screen(mod, mod) end

    activate!(
      files(%{"kit_card.ex" => card.("Kit.Card"), "gallery_card.ex" => card.("Gallery.Card")})
    )

    start_front(settings)
    assert Front.screens() == ["Gallery.Card", "Home", "Kit.Card", "Second"]

    assert {:ok, "Second"} = Front.open("Second")
    assert {:ok, "Home"} = Front.open(" Operator.Dyn.Home ")
    assert {:ok, "Kit.Card"} = Front.open("Kit.Card")
    assert {:error, {:ambiguous, ["Gallery.Card", "Kit.Card"]}} = Front.open("Card")
    assert {:error, :unknown_screen} = Front.open("Helpers")
    assert {:error, :unknown_screen} = Front.open("Nope")

    # It becomes the whole stack, also for the next launch.
    assert %{stack: ["Kit.Card"]} = Front.status()
    assert Settings.front_stack(settings) == ["Kit.Card"]
  end

  test "the toggle's symbol is the dial or 1 to 8 characters" do
    assert Front.validate_toggle(:dial) == {:ok, :dial}
    assert Front.validate_toggle({:text, " ☎ "}) == {:ok, {:text, "☎"}}
    assert Front.validate_toggle({:text, "12345678"}) == {:ok, {:text, "12345678"}}
    assert {:error, _} = Front.validate_toggle({:text, "123456789"})
    assert {:error, _} = Front.validate_toggle({:text, "  "})
    assert {:error, _} = Front.validate_toggle({:image, "x.png"})
    assert {:error, _} = Front.validate_toggle(nil)
  end

  test "settings that are invalid or raise fall back to the dial and the first screen",
       %{settings: settings} do
    activate!(files(%{"front.ex" => settings("Operator.Dyn.Helpers", ~s|{:text, ""}|)}))
    start_front(settings)
    assert Front.screens() == ["Home", "Second"]
    assert Front.toggle() == :dial
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("home 0")

    # The whole module is read in one go: a raise loses both settings.
    activate!(%{"front.ex" => settings("Operator.Dyn.Second", ~s|raise "no toggle"|)})
    await_view("home 0")
    assert Front.toggle() == :dial
  end

  test "the front tools list, open and photograph the front", %{settings: settings} do
    activate!(files())
    start_front(settings)

    assert {:ok, listing} = FrontScreens.run(%{}, %{})
    assert listing =~ "Open: none yet"
    assert listing =~ "the user is in the terminal"
    assert listing =~ "2 front screens:\nHome\nSecond"

    assert {:error, "No front screen is called Sec" <> _} =
             FrontOpen.run(%{"screen" => "Sec"}, %{})

    assert {:ok, "The front shows Second now" <> _} = FrontOpen.run(%{"screen" => "Second"}, %{})
    assert {:error, _} = FrontOpen.run(%{}, %{})

    _ = Front.subscribe()
    _ = Front.show(@env)
    second = await_view("second 0")
    assert {:ok, listing} = FrontScreens.run(%{}, %{})
    assert listing =~ "Open: Second (the front is on screen)\nIt runs."

    send(second.host, {:tap, :back})
    send(second.host, :ignored)
    Front.open("Home")
    home = await_view("home 0")
    tap_front(home, :boom)
    await_view("boom")
    assert {:ok, listing} = FrontScreens.run(%{}, %{})
    assert listing =~ "It crashed:\n** (RuntimeError) boom from home"

    # The screenshot is an image result, through the tool runner as the loop runs it.
    capture = fn Front -> {:ok, <<0xFF, 0xD8, 0xFF>>} end
    sup = start_supervised!(Task.Supervisor)
    ctx = %{front_capture: capture}

    task =
      ToolRunner.start(
        sup,
        self(),
        FrontScreenshot,
        %{"arguments" => %{}},
        &ToolRunner.allow_all/2,
        ctx
      )

    assert {:ok,
            {:images, [{"image/jpeg", <<0xFF, 0xD8, 0xFF>>}],
             "Screenshot of the front, showing Home."}} = Task.await(task)

    failing = %{front_capture: fn _ -> {:error, "the screenshot failed: :no_window"} end}
    assert {:error, "the screenshot failed: :no_window"} = FrontScreenshot.run(%{}, failing)
  end
end
