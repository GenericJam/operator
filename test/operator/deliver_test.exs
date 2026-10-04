defmodule Operator.DeliverTest do
  # async: false: mob_deliver's environment and mob's router hooks are VM-wide.
  use Mob.ScreenCase, async: false

  alias Operator.Core.Settings
  alias Operator.Deliver
  alias Operator.Links
  alias Operator.LoginScanScreen

  @moduletag :tmp_dir
  @moduletag :capture_log
  @endpoint "http://192.168.1.20:8040/deliver"

  defp public_key, do: "ed25519:" <> Base.encode64(:crypto.strong_rand_bytes(32))

  # This build's publish key, for one test.
  defp build_key(key) do
    previous = Application.get_env(:mob_deliver, :trusted_publish_key)
    Application.put_env(:mob_deliver, :trusted_publish_key, key)
    on_exit(fn -> Application.put_env(:mob_deliver, :trusted_publish_key, previous) end)
  end

  defp params(link) do
    {:ok, params} = Links.params(link, "deliver")
    params
  end

  setup do
    previous = Application.get_env(:mob_deliver, :endpoint)

    on_exit(fn ->
      Application.put_env(:mob_deliver, :endpoint, previous)
      :persistent_term.erase({Deliver, :endpoint_at_launch})
    end)
  end

  test "a link for this build's key gives its server; another key, no key or a bad address don't" do
    key = public_key()
    build_key(key)
    assert Deliver.parse(params(Deliver.link(@endpoint, key))) == {:ok, @endpoint}

    assert {:error, "That update-server code is for another signing key" <> _} =
             Deliver.parse(params(Deliver.link(@endpoint, public_key())))

    for bad <- ["ftp://192.168.1.20/deliver", "192.168.1.20:8040", "http://", "http:/x/deliver"] do
      assert {:error, "That update-server code has no valid address."} =
               Deliver.parse(params(Deliver.link(bad, key)))
    end

    assert {:error, _} = Deliver.parse(%{"key" => "x"})

    build_key(nil)
    assert {:error, text} = Deliver.parse(params(Deliver.link(@endpoint, key)))
    assert text =~ "mix operator.deliver.key"
  end

  test "Operator.Links hands an update-server link over for confirmation, saving nothing" do
    key = public_key()
    build_key(key)

    assert {:error, "That update-server code is for another" <> _} =
             Links.handle(Deliver.link(@endpoint, public_key()))

    assert Links.handle(Deliver.link(@endpoint, key)) == {:deliver, @endpoint}
    assert Settings.deliver_endpoint() == nil
    assert Deliver.endpoint() == nil
  end

  test "the scanner asks before using a server, showing the one in use", %{tmp_dir: dir} do
    key = public_key()
    build_key(key)
    :ok = Settings.put_deliver_endpoint(@endpoint, dir)
    :ok = Deliver.apply_saved_endpoint(dir)
    other = "http://10.0.0.5:8040/deliver"

    # Cancelled: nothing changes.
    view = mount_screen(LoginScanScreen, %{data_dir: dir})
    view = render_info(view, {:scan, :result, %{value: Deliver.link(other, key)}})
    assert text(view) =~ "Get Operator's code updates from #{other}? (now #{@endpoint})"
    view = render_info(view, {:tap, :keep_server})
    assert text(view) =~ "Update server not changed."
    assert Settings.deliver_endpoint(dir) == @endpoint
    assert Deliver.endpoint() == @endpoint

    # Another link lands while the question shows: a tap on the button that
    # showed the first address saves neither.
    local = "http://127.0.0.1:1/deliver"
    view = mount_screen(LoginScanScreen, %{data_dir: dir, deliver: local})
    assert_renderable(view)
    view = render_info(view, {:scan, :result, %{value: Deliver.link(other, key)}})
    view = render_info(view, {:tap, {:use_server, local}})
    assert Settings.deliver_endpoint(dir) == @endpoint
    assert text(view) =~ "Get Operator's code updates from #{other}?"

    # Opened by the chat for a link from another app, then confirmed. Update
    # checks ran at this launch, so it checks at once (here against nothing).
    view = mount_screen(LoginScanScreen, %{data_dir: dir, deliver: local})
    view = render_info(view, {:tap, {:use_server, local}})
    assert text(view) =~ "Update server set to #{local}: checking for updates."
    assert Settings.deliver_endpoint(dir) == local
    assert Deliver.endpoint() == local
  end

  test "the first server saved on a phone without one asks for a restart", %{tmp_dir: dir} do
    :ok = Deliver.apply_saved_endpoint(dir)
    assert Deliver.endpoint() == nil

    assert Deliver.save(@endpoint, dir) =~ "Close Operator and open it again"
    assert Settings.deliver_endpoint(dir) == @endpoint
    assert Deliver.endpoint() == @endpoint
  end

  test "the Keeper learns which update this launch runs and which one was rolled back" do
    now = DateTime.utc_now()
    active = %{active: %{id: "cur", issued_at: now}}

    assert Deliver.boot_opts(active, %{rolled_back: "bad", at: now}) ==
             [core: "cur", core_rolled_back: "bad"]

    # A notice from an earlier launch says nothing about the last one.
    assert Deliver.boot_opts(%{active: nil}, %{
             rolled_back: "bad",
             at: DateTime.add(now, -1, :day)
           }) ==
             [core: nil, core_rolled_back: nil]

    assert Deliver.boot_opts(%{active: nil}, nil) == [core: nil, core_rolled_back: nil]
  end

  test "taking over probation removes mob_deliver's first-frame proof, not its navigation hook" do
    hooks = {Mob.Router.Hooks, :hooks}
    saved = :persistent_term.get(hooks, %{})
    on_exit(fn -> :persistent_term.put(hooks, saved) end)

    :ok = MobDeliver.Hooks.register()
    registered = fn hook -> :persistent_term.get(hooks, %{}) |> Map.get(hook, []) end
    assert Enum.any?(registered.(:after_first_render), &match?({MobDeliver.Hooks, _, _}, &1))

    assert Deliver.take_over_probation() == :ok
    refute Enum.any?(registered.(:after_first_render), &match?({MobDeliver.Hooks, _, _}, &1))
    assert Enum.any?(registered.(:before_navigate), &match?({MobDeliver.Hooks, _, _}, &1))
  end
end
