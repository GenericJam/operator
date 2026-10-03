defmodule Operator.DeliverTest do
  # async: false: mob_deliver's environment and mob's router hooks are VM-wide.
  use ExUnit.Case, async: false

  alias Operator.Core.Settings
  alias Operator.Deliver
  alias Operator.Links

  @moduletag :tmp_dir
  @endpoint "http://192.168.1.20:8040/deliver"

  defp public_key, do: "ed25519:" <> Base.encode64(:crypto.strong_rand_bytes(32))

  # This build's trust root, for one test.
  defp trust(key) do
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

  test "a link from the Mac signing with the build's key sets the update server", %{tmp_dir: dir} do
    key = public_key()
    trust(key)

    assert {:ok, text} = Deliver.configure(params(Deliver.link(@endpoint, key)), dir)
    assert text =~ @endpoint
    # mob_deliver had no endpoint at this launch, so it isn't checking yet.
    assert text =~ "open it again"
    assert Settings.deliver_endpoint(dir) == @endpoint
    assert Application.get_env(:mob_deliver, :endpoint) == @endpoint
  end

  test "a link for another key, a build without a key or a bad address changes nothing",
       %{tmp_dir: dir} do
    trust(public_key())
    other = Deliver.link(@endpoint, public_key())
    assert {:error, text} = Deliver.configure(params(other), dir)
    assert text =~ "another key"

    trust(nil)
    assert {:error, text} = Deliver.configure(params(other), dir)
    assert text =~ "mix operator.deliver.key"

    key = public_key()
    trust(key)

    for bad <- ["ftp://192.168.1.20/deliver", "192.168.1.20:8040", "http://"] do
      assert {:error, _} = Deliver.configure(params(Deliver.link(bad, key)), dir)
    end

    assert {:error, _} = Deliver.configure(%{"key" => "x"}, dir)
    assert Settings.deliver_endpoint(dir) == nil
    assert Application.get_env(:mob_deliver, :endpoint) == nil
  end

  test "Operator.Links routes operator://deliver links" do
    key = public_key()
    trust(key)

    assert {:error, "That update server signs with another key" <> _} =
             Links.handle(Deliver.link(@endpoint, public_key()))

    assert {:deliver, text} = Links.handle(Deliver.link(@endpoint, key))
    assert text =~ @endpoint
    assert Settings.deliver_endpoint() == @endpoint
  end

  test "the saved endpoint is in mob_deliver's environment before mob starts it",
       %{tmp_dir: dir} do
    assert Deliver.apply_saved_endpoint(dir) == :ok
    assert Application.get_env(:mob_deliver, :endpoint) == nil

    :ok = Settings.put_deliver_endpoint(@endpoint, dir)
    assert Deliver.apply_saved_endpoint(dir) == :ok
    assert Application.get_env(:mob_deliver, :endpoint) == @endpoint

    # mob_deliver started its checks with it: a new link checks at once
    # (here against a closed port).
    key = public_key()
    trust(key)
    other = "http://127.0.0.1:1/deliver"
    assert {:ok, text} = Deliver.configure(params(Deliver.link(other, key)), dir)
    assert text =~ "checking for updates"
    assert Settings.deliver_endpoint(dir) == other
  end

  test "a rollback notice from this launch means the last launch failed on the Core" do
    now = DateTime.utc_now()
    assert Deliver.rolled_back_this_launch?(%{rolled_back: "abc", at: now})

    refute Deliver.rolled_back_this_launch?(%{
             rolled_back: "abc",
             at: DateTime.add(now, -1, :day)
           })

    refute Deliver.rolled_back_this_launch?(nil)
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
