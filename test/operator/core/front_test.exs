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
  alias Operator.Core.Tools.FrontScroll
  alias Operator.Core.Tools.FrontSend
  alias Operator.Core.Tools.FrontState
  alias Operator.Core.Tools.FrontTap

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

    # Any other message (a native result, decoded or raw) goes back to the
    # test, with what keeping its path gives.
    def handle_info(message, socket) do
      kept =
        case message do
          {_kind, _tag, %{path: path}} -> Files.keep(path)
          {_kind, :picked, [%{path: path} | _]} -> Files.keep(path)
          _ -> :nothing
        end

      send(socket.assigns.owner, {:got, message, kept})
      {:noreply, socket}
    end
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

    def render(assigns) do
      %{type: :column, props: %{}, children: [
        %{type: :text, props: %{text: "second \#{assigns.n}"}, children: []},
        %{type: :button, props: %{text: "Start over", on_tap: {self(), :reset}}, children: []}
      ]}
    end

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

  test "the host decodes a raw native file result as mob does and grants its paths",
       %{tmp_dir: dir} do
    old_temp = Application.get_env(:operator, :app_temp)
    old_data = System.get_env("MOB_DATA_DIR")
    temp = Path.join(dir, "native-temp")
    File.mkdir_p!(temp)
    for name <- ~w(rec.m4a shot.jpg pick.jpg), do: File.write!(Path.join(temp, name), name)
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

    {host, _monitor, key} =
      Host.start(self(), [{LifecycleFile, %{owner: self()}}], @env, &(&1 == LifecycleFile))

    assert_receive {:operator_front_host, ^host, {:view, _}}
    rec = Path.join(temp, "rec.m4a")

    # What Mob.Audio's NIF sends the process that started the recording.
    send(
      host,
      {:mob_file_result, "audio", "recorded",
       JSON.encode!([%{"path" => rec, "duration" => 1.5, "not_an_atom_qz7" => 1}])}
    )

    assert_receive {:got, {:audio, :recorded, item}, {:ok, kept}}, 1_000
    assert %{:path => ^rec, :duration => 1.5, "not_an_atom_qz7" => 1} = item
    assert File.read!(kept) == "rec.m4a"

    shot = Path.join(temp, "shot.jpg")
    send(host, {:mob_file_result, "camera", "photo", JSON.encode!([%{path: shot, width: 4}])})
    assert_receive {:got, {:camera, :photo, %{path: ^shot, width: 4}}, {:ok, _}}, 1_000

    # Through the shell (a result that reached the router), raw or decoded.
    pick = Path.join(temp, "pick.jpg")
    raw = {:mob_file_result, "photos", "picked", JSON.encode!([%{path: pick}])}
    send(host, {Host, :native, key, raw})
    assert_receive {:got, {:photos, :picked, [%{path: ^pick}]}, {:ok, _}}, 1_000

    # A new result grants its path again (a grant is spent by one keep);
    # unknown or broken results pass through unchanged.
    send(host, {:mob_file_result, "audio", "recorded", JSON.encode!([%{path: rec}])})
    assert_receive {:got, {:audio, :recorded, _}, {:ok, _}}, 1_000

    unknown = {:mob_file_result, "no_such_event_qz7", "done", "[]"}
    send(host, unknown)
    assert_receive {:got, ^unknown, :nothing}, 1_000
    broken = {:mob_file_result, "audio", "recorded", "not json"}
    send(host, broken)
    assert_receive {:got, ^broken, :nothing}, 1_000

    assert {:media, :listed, [%{uri: "content://1"}]} =
             Host.decode_native(
               {:mob_file_result, "media", "listed", ~s|[{"uri":"content://1"}]|}
             )

    assert {:scan, :result, %{type: :qr, value: "x"}} =
             Host.decode_native({:mob_file_result, "scan", "result", ~s|[{"value":"x"}]|})

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
    assert listing =~ "Open: Second (the front is on screen, generation G1)\nIt runs."

    assert {:error, text} = FrontTap.run(%{"tag" => "nope"}, %{})
    assert text =~ "no tag nope. Its tappable tags:\n- reset (Start over)"

    assert {:ok, "Tapped reset on Second; it re-rendered."} =
             FrontTap.run(%{"tag" => "reset"}, %{})

    await_view("second 9")

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

    # Another app's window over Operator: the shot looks normal, the text says so.
    covered = %{front_capture: capture, foreground?: fn -> false end}

    assert {:ok, {:image, _, _, "Screenshot of the front, showing Home.\n\nWarning: " <> warning}} =
             FrontScreenshot.run(%{}, covered)

    assert warning =~ "Operator isn't the focused app right now"
    assert warning =~ "Back"
    assert Front.cover_warning(true) == nil
    assert Front.app_foreground?()
  end

  @cam """
  defmodule Operator.Dyn.Cam do
    use Mob.Screen
    alias Operator.Core.Files

    def mount(_params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, shown: "none", slow: 0)}

    def render(assigns) do
      %{type: :column, props: %{}, children: [
        %{type: :text, props: %{text: "cam \#{assigns.shown}"}, children: []},
        %{type: :text, props: %{text: "slow \#{assigns.slow}"}, children: []},
        %{type: :button, props: %{text: "Same", on_tap: {self(), :same}}, children: []},
        %{type: :button, props: %{text: "Slow", on_tap: {self(), :slow}}, children: []}
      ]}
    end

    def handle_info({:camera, kind, %{path: path}}, socket) when kind in [:photo, :video] do
      shown =
        with {:ok, kept} <- Files.keep(path, "shot" <> Path.extname(path)),
             {:ok, bytes} <- Files.read(kept) do
          "kept \#{Path.basename(kept)} \#{bytes}"
        else
          _ -> "refused"
        end

      {:noreply, Mob.Socket.assign(socket, :shown, shown)}
    end

    def handle_info({:tap, :boom}, _socket), do: raise("cam boom")

    def handle_info({:tap, :slow}, socket) do
      Process.sleep(300)
      {:noreply, Mob.Socket.assign(socket, :slow, socket.assigns.slow + 1)}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end
  """

  test "front_tap and front_send say whether the screen re-rendered or crashed; a sent " <>
         "camera reply reaches the screen as the phone's would",
       %{settings: settings, tmp_dir: dir} do
    old_temp = Application.get_env(:operator, :app_temp)
    old_data = System.get_env("MOB_DATA_DIR")
    temp = Path.join(dir, "native-temp")
    data = Path.join(dir, "data")
    File.mkdir_p!(temp)
    File.mkdir_p!(Path.join(data, "workspace/inbox"))
    File.write!(Path.join(data, "workspace/inbox/src.jpg"), "pixels")
    File.write!(Path.join(data, "workspace/inbox/clip.mp4"), "frames")
    File.write!(Path.join(temp, "other.jpg"), "someone else's")
    Application.put_env(:operator, :app_temp, temp)
    System.put_env("MOB_DATA_DIR", data)

    on_exit(fn ->
      if old_temp,
        do: Application.put_env(:operator, :app_temp, old_temp),
        else: Application.delete_env(:operator, :app_temp)

      if old_data,
        do: System.put_env("MOB_DATA_DIR", old_data),
        else: System.delete_env("MOB_DATA_DIR")
    end)

    activate!(files(%{"cam.ex" => @cam}))
    start_front(settings)
    ctx = %{data_dir: data}

    assert {:error, "No front screen is running" <> _} =
             FrontSend.run(%{"message" => ":ok"}, ctx)

    {:ok, "Cam"} = Front.open("Cam")
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("cam none")

    # The tap arrives but changes nothing: said so, not passed off as done.
    assert {:ok, "Tapped same on Cam; the screen did not re-render within 1 s" <> _} =
             FrontTap.run(%{"tag" => "same"}, %{})

    # A workspace file named in the reply reaches the screen as a fresh
    # temporary copy, which Files.keep/2 takes.
    assert {:ok, "Sent {:camera, :photo, %{" <> rest} =
             FrontSend.run(
               %{"message" => ~s|{:camera, :photo, %{path: "inbox/src.jpg", width: 600}}|},
               ctx
             )

    assert rest =~ "to Cam; it re-rendered."
    await_view("cam kept shot.jpg pixels")

    # A video too.
    assert {:ok, _} =
             FrontSend.run(%{"message" => ~s|{:camera, :video, %{path: "inbox/clip.mp4"}}|}, ctx)

    await_view("cam kept shot.mp4 frames")

    # The screen got them, but another app's window takes the user's touches: said so.
    covered = Map.put(ctx, :foreground?, fn -> false end)

    assert {:ok, "Tapped same on Cam; the screen did not re-render" <> rest} =
             FrontTap.run(%{"tag" => "same"}, covered)

    assert rest =~ "front_screenshot.\n\nWarning: Operator isn't the focused app"

    assert {:ok, "Sent {:tap, :same} to Cam" <> rest} =
             FrontSend.run(%{"message" => "{:tap, :same}"}, covered)

    assert rest =~ "\n\nWarning: Operator isn't the focused app"

    # Only workspace files: a temporary file it names is not staged or granted.
    assert {:error, text} =
             FrontSend.run(
               %{"message" => ~s|{:camera, :photo, %{path: "#{temp}/other.jpg"}}|},
               ctx
             )

    assert text =~ "outside the places files may be used"

    assert {:error, "unknown atom front_send_no_such_atom_q7" <> _} =
             FrontSend.run(%{"message" => "{:front_send_no_such_atom_q7}"}, ctx)

    assert {:error, "`System.halt()` is not a literal" <> _} =
             FrontSend.run(%{"message" => "{:ok, System.halt()}"}, ctx)

    assert {:error, "Sent {:tap, :boom} to Cam; the screen crashed:\n" <> error} =
             FrontSend.run(%{"message" => "{:tap, :boom}"}, ctx)

    assert error =~ "cam boom"
    assert {:error, "No front screen is running" <> _} = FrontTap.run(%{"tag" => "same"}, %{})
  end

  test "front tools from different callers take turns on the front", %{settings: settings} do
    activate!(files(%{"cam.ex" => @cam}))
    start_front(settings)
    {:ok, "Cam"} = Front.open("Cam")
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("cam none")

    # Two callers at once (say a subagent's loop and eval): the second tap
    # waits for the first to finish, so each sees its own re-render.
    started = System.monotonic_time(:millisecond)
    taps = for _ <- 1..2, do: Task.async(fn -> FrontTap.run(%{"tag" => "slow"}, %{}) end)

    assert [{:ok, "Tapped slow on Cam; it re-rendered."}, {:ok, "Tapped slow on Cam" <> _}] =
             Task.await_many(taps, 5_000)

    assert System.monotonic_time(:millisecond) - started >= 550
    assert {:ok, "Cam assigns:\n%{slow: 2}"} = FrontState.run(%{"keys" => ["slow"]}, %{})

    # Busy past the wait: an error, and nothing runs. A holder that dies frees it.
    test = self()

    holder =
      spawn(fn ->
        Front.exclusive(fn ->
          send(test, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    assert {:error, :busy} = Front.exclusive(fn -> :ran end, Front, 50)
    Process.exit(holder, :kill)
    assert :ran = Front.exclusive(fn -> :ran end, Front, 1_000)

    # Re-entrant within one caller.
    assert :inner = Front.exclusive(fn -> Front.exclusive(fn -> :inner end, Front, 0) end)
  end

  test "front_send parses literals only" do
    assert {:ok, {:photos, :picked, [%{path: "a.jpg", size: -1, ratio: 1.5}], [a: nil]}} =
             FrontSend.parse(
               ~s|{:photos, :picked, [%{path: "a.jpg", size: -1, ratio: 1.5}], [a: nil]}|
             )

    assert {:ok, %{"k" => {1, 2, 3}}} = FrontSend.parse(~s|%{"k" => {1, 2, 3}}|)
    assert {:ok, Operator.Core.Front} = FrontSend.parse("Operator.Core.Front")
    assert {:error, "`path` is a variable" <> _} = FrontSend.parse("{:camera, :photo, path}")
    assert {:error, "a pin" <> _} = FrontSend.parse("^x")
    assert {:error, "`File.rm(\"a\")` is not a literal" <> _} = FrontSend.parse(~s|File.rm("a")|)

    assert {:error, "`%Operator.Core.Front{}` is not a literal" <> _} =
             FrontSend.parse("%Operator.Core.Front{}")

    assert {:error, "not valid Elixir" <> _} = FrontSend.parse("{:ok,")
    assert FrontSend.selftest() == :ok
  end

  # Stands in for mob's scroll NIFs: scroll views by id in the test
  # process's dictionary (the tool runs them there, `front_show` below).
  defmodule FakeScrollNif do
    def scroll_info(id) do
      case Process.get({:scroll, id}) do
        nil ->
          {:error, :scroll_view_not_found}

        y ->
          JSON.encode!(%{
            offset_x: 0,
            offset_y: y,
            content_w: 400,
            content_h: 2500,
            viewport_w: 400,
            viewport_h: 1000,
            max_x: 0,
            max_y: 1500,
            kind: "pixel"
          })
      end
    end

    def scroll_to(id, x, y) when is_binary(id) and is_float(x) and is_float(y) do
      Process.put({:scroll, id}, y)
      :ok
    end
  end

  @scrolly """
  defmodule Operator.Dyn.Scrolly do
    use Mob.Screen

    def mount(_params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, mode: :none, note: String.duplicate("n", 2000))}

    def render(%{mode: mode}) do
      text = fn t -> %{type: :text, props: %{text: t}, children: []} end
      scroll = fn props, t -> %{type: :scroll, props: props, children: [text.(t)]} end

      kids =
        case mode do
          :none -> [text.("no scroll")]
          :bare -> [scroll.(%{}, "bare rows")]
          :one -> [scroll.(%{id: :feed}, "feed rows"), scroll.(%{}, "unnamed")]
          :two -> [scroll.(%{id: :a}, "rows a"), scroll.(%{id: "b"}, "rows b")]
        end

      %{type: :column, props: %{}, children: kids}
    end

    def handle_info({:mode, mode}, socket), do: {:noreply, Mob.Socket.assign(socket, :mode, mode)}
    def handle_info(_message, socket), do: {:noreply, socket}
  end
  """

  test "front_state shows the open screen's assigns, all or the keys asked for",
       %{settings: settings} do
    activate!(files(%{"scrolly.ex" => @scrolly}))
    start_front(settings)

    assert {:error, "No front screen is running" <> _} = FrontState.run(%{}, %{})

    {:ok, "Scrolly"} = Front.open("Scrolly")
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("no scroll")
    {:ok, "Scrolly", :rendered} = Front.deliver({:mode, :two})

    assert {:ok, "Scrolly assigns:\n" <> all} = FrontState.run(%{}, %{})
    assert all =~ "mode: :two"
    assert all =~ "safe_area:"
    # Long strings are cut.
    refute all =~ String.duplicate("n", 600)

    assert {:ok, "Scrolly assigns:\n%{mode: :two}\n(no assign nope; it has: " <> has} =
             FrontState.run(%{"keys" => ["mode", "nope"]}, %{})

    assert has =~ "mode, note"
  end

  test "front_scroll finds the screen's one scroll view with an id and scrolls it by page",
       %{settings: settings} do
    activate!(files(%{"scrolly.ex" => @scrolly}))
    start_front(settings)

    shown = fn _front, while_shown ->
      with {:ok, text} <- while_shown.(), do: {:ok, text, <<0xFF, 0xD8>>}
    end

    ctx = %{scroll_nif: FakeScrollNif, front_show: shown}
    scroll = fn args -> FrontScroll.run(args, ctx) end

    assert {:error, "No front screen is running" <> _} = scroll.(%{"to" => "down"})

    {:ok, "Scrolly"} = Front.open("Scrolly")
    _ = Front.subscribe()
    _ = Front.show(@env)
    await_view("no scroll")

    assert {:error, "`to` must be" <> _} = scroll.(%{"to" => "0"})
    assert {:error, "`to` is required" <> _} = scroll.(%{})
    assert {:error, "The open front screen has no scroll view" <> _} = scroll.(%{"to" => "down"})

    {:ok, _, :rendered} = Front.deliver({:mode, :bare})

    assert {:error, "The open front screen's scroll view has no `id`" <> _} =
             scroll.(%{"to" => "down"})

    {:ok, _, :rendered} = Front.deliver({:mode, :two})

    assert {:error, "The open front screen has several scroll views; give `id`:\n" <> listed} =
             scroll.(%{"to" => "down"})

    assert listed == "- a (rows a)\n- b (rows b)"

    {:ok, _, :rendered} = Front.deliver({:mode, :one})
    Process.put({:scroll, "feed"}, 0)

    assert {:ok, {:image, "image/jpeg", <<0xFF, 0xD8>>, text}} = scroll.(%{"to" => "down"})
    assert text =~ "Scrolled feed: page 2 of 3, offset 1000 of 1500 px"

    assert {:ok, {:image, _, _, text}} = scroll.(%{"to" => "down"})
    assert text =~ "page 3 of 3, offset 1500 of 1500"
    assert {:ok, {:image, _, _, text}} = scroll.(%{"to" => "bottom"})
    assert text =~ "It was already at the bottom."
    assert {:ok, {:image, _, _, text}} = scroll.(%{"to" => "2"})
    assert text =~ "page 2 of 3, offset 1000"
    assert {:ok, {:image, _, _, text}} = scroll.(%{"to" => "top"})
    assert text =~ "page 1 of 3, offset 0"

    assert {:ok, {:image, _, _, text}} =
             FrontScroll.run(%{"to" => "down"}, Map.put(ctx, :foreground?, fn -> false end))

    assert text =~ "Screenshot of the front:\n\nWarning: Operator isn't the focused app"

    assert {:error, "No scroll view with id gone is on screen" <> _} =
             scroll.(%{"to" => "down", "id" => "gone"})

    assert FrontScroll.selftest() == :ok
    assert FrontState.selftest() == :ok
  end
end
