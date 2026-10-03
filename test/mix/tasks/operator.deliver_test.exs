defmodule Mix.Tasks.Operator.DeliverTest do
  # async: false: Mix.shell/1, mob_deliver's environment and loaded probe
  # modules are VM-wide.
  use ExUnit.Case, async: false

  alias Mix.Operator.Deliver
  alias Mix.Tasks.Operator.Deliver.Key
  alias MobDeliver.Client
  alias MobDeliverServer.Storage.FS
  alias Operator.Core.Settings
  alias Operator.Links

  @moduletag :tmp_dir
  @app "com.genericjam.operator"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    endpoint = Application.get_env(:mob_deliver, :endpoint)
    trusted = Application.get_env(:mob_deliver, :trusted_publish_key)

    on_exit(fn ->
      Mix.shell(shell)
      Application.put_env(:mob_deliver, :endpoint, endpoint)
      Application.put_env(:mob_deliver, :trusted_publish_key, trusted)
    end)
  end

  defp sha256(binary), do: Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

  # A build entry for a module compiled from `source` (loaded meanwhile).
  defp entry(source) do
    [{module, beam}] = Code.compile_string(source)
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    stripped = Deliver.strip(beam)
    {MobDeliverServer.module_key(module), {sha256(stripped), stripped}}
  end

  test "operator.deliver.key writes a 0600 key, prints its public half, never replaces it",
       %{tmp_dir: dir} do
    path = Path.join([dir, "config", "deliver_signing.key"])
    Key.run(["--out", path])

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    key = Deliver.read_private_key!(path)
    assert_received {:mix_shell, :info, [text]}
    assert text =~ Deliver.public_key(key)

    assert_raise Mix.Error, ~r/refusing to replace/, fn ->
      Key.run(["--out", path])
    end

    assert Deliver.read_private_key!(path) == key
  end

  test "a publish carries Operator's modules, not the entry module, the build's config, " <>
         "NIF stubs or Mix tasks",
       %{tmp_dir: dir} do
    keys = Mix.Project.compile_path() |> Deliver.build() |> Map.keys()

    for key <- ~w(Operator.App Operator.Core.Loop Operator.Core.Dyn.Keeper Operator.ChatScreen
                  Operator.Deliver Operator.Links) do
      assert key in keys
    end

    refute ":operator" in keys
    refute "Operator.Nifs.OperatorSecureStore" in keys
    refute Enum.any?(keys, &String.starts_with?(&1, "Mix."))

    # mob_dev writes the build's config module into the same ebin at deploy.
    {:ok, :mob_app_config, config} =
      :compile.forms(
        [
          {:attribute, 1, :module, :mob_app_config},
          {:attribute, 1, :export, [config: 0]},
          {:function, 1, :config, 0, [{:clause, 1, [], [], [{nil, 1}]}]}
        ],
        [:binary]
      )

    loop = Path.join(Mix.Project.compile_path(), "Elixir.Operator.Core.Loop.beam")
    File.write!(Path.join(dir, "mob_app_config.beam"), config)
    File.cp!(loop, Path.join(dir, "Elixir.Operator.Core.Loop.beam"))
    assert %{"Operator.Core.Loop" => {sha, beam}} = build = Deliver.build(dir)
    assert map_size(build) == 1

    # Stripped: what the VM needs, no checkout path (the SHA is the same
    # wherever the checkout lives), the code unchanged.
    assert sha == sha256(beam)
    assert :binary.match(beam, File.cwd!()) == :nomatch
    assert {:ok, {_, md5}} = :beam_lib.md5(beam)
    assert {:ok, {_, ^md5}} = :beam_lib.md5(File.read!(loop))
  end

  test "published, served over HTTP, found by the phone's QR and fetched by mob_deliver",
       %{tmp_dir: dir} do
    private_key = MobDeliverServer.Manifest.generate_private_key()
    public_key = Deliver.public_key(private_key)
    store = Path.join(dir, "store")
    opts = [root: store, app: @app, channel: "dev", private_key: private_key]
    {probe, probe_v1} = entry("defmodule Operator.RoundTripProbe do\n  def v, do: 1\nend\n")
    build = Mix.Project.compile_path() |> Deliver.build() |> Map.put(probe, probe_v1)

    assert {:ok, %{previous_issued_at: nil, removed: []} = first} = Deliver.publish(build, opts)
    assert length(first.changed) == map_size(build)

    {:ok, _} = Application.ensure_all_started(:bandit)

    server =
      start_supervised!(
        {Bandit,
         plug: {Deliver.Server, storage: {FS, root: store}},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    endpoint = Deliver.endpoint("127.0.0.1", port)

    # The phone scans the QR; its build trusts this key.
    Application.put_env(:mob_deliver, :trusted_publish_key, public_key)
    {:ok, params} = Links.params(Operator.Deliver.link(endpoint, public_key), "deliver")
    assert {:ok, ^endpoint} = Operator.Deliver.parse(params)
    Operator.Deliver.save(endpoint, dir)

    client = [
      endpoint: Settings.deliver_endpoint(dir),
      app: @app,
      channel: "dev",
      trusted_publish_key: public_key
    ]

    assert {:ok, manifest, _body} = Client.fetch_manifest(client)
    assert manifest.modules == Map.new(build, fn {key, {sha, _beam}} -> {key, sha} end)

    for key <- [probe, "Operator.Core.Loop"] do
      {sha, beam} = build[key]
      assert Client.fetch_beam(sha, client) == {:ok, beam}
    end

    # The next publish: one module changed, one gone; the phone sees it.
    {^probe, probe_v2} = entry("defmodule Operator.RoundTripProbe do\n  def v, do: 2\nend\n")
    next = build |> Map.put(probe, probe_v2) |> Map.delete("Operator.Diag")

    assert {:ok, %{changed: [{"changed", ^probe}], removed: ["Operator.Diag"]} = second} =
             Deliver.publish(next, opts)

    assert second.previous_issued_at == first.fields["issued_at"]
    assert {:ok, manifest, _body} = Client.fetch_manifest(client)
    assert manifest.modules[probe] == elem(probe_v2, 0)
    refute Map.has_key?(manifest.modules, "Operator.Diag")

    # Signed with another key: the phone refuses it.
    other = Deliver.public_key(MobDeliverServer.Manifest.generate_private_key())

    assert Client.fetch_manifest(Keyword.put(client, :trusted_publish_key, other)) ==
             {:error, :invalid_signature}
  end

  test "the Mac's LAN address: a private IPv4 that is up, the default route's interface first" do
    up = [:up, :broadcast, :running, :multicast]

    interfaces = [
      {~c"lo0", [flags: [:up, :loopback, :running], addr: {127, 0, 0, 1}]},
      {~c"utun4", [flags: [:up, :pointtopoint, :running], addr: {10, 8, 0, 2}]},
      {~c"bridge100", [flags: up, addr: {192, 168, 64, 1}]},
      {~c"en2", [flags: [:broadcast], addr: {192, 168, 1, 30}]},
      {~c"en5", [flags: up, addr: {172, 20, 0, 9}]},
      # Ethernet the Mac shares its connection on; Wi-Fi carries the default route.
      {~c"en0", [flags: up, addr: {192, 168, 50, 1}]},
      {~c"en1", [flags: up, addr: {0xFE80, 0, 0, 0, 1, 2, 3, 4}, addr: {10, 0, 0, 71}]}
    ]

    assert Deliver.lan_ip({:ok, interfaces}, "en1") == "10.0.0.71"
    assert Deliver.lan_ip({:ok, Enum.drop(interfaces, -2)}, nil) == "172.20.0.9"
    assert Deliver.lan_ip({:ok, [hd(interfaces)]}, nil) == nil
    assert Deliver.lan_ip({:error, :enotsup}, "en1") == nil
  end
end
