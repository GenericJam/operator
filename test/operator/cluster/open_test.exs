defmodule Operator.Cluster.OpenTest do
  # Starts real (plain TCP) distribution in this VM, as the phone does in
  # open mode, against stock `:peer` nodes: the VM's node name is app-wide.
  use ExUnit.Case, async: false

  alias Operator.Cluster

  @moduletag :tmp_dir
  @cookie "phonecookie"

  setup %{tmp_dir: dir} do
    # Registered first, so even a setup that fails after distribution
    # starts leaves none behind, nor open-mode settings.
    on_exit(fn ->
      Node.stop()
      :operator_epmd.set_mode(:fixed)

      for key <- [:epmd_module, :operator_dist_port, :inet_dist_use_interface],
          do: Application.delete_env(:kernel, key)
    end)

    start_supervised!(
      {Cluster,
       dir: Path.join(dir, "cluster"), boot_dist: false, address: {127, 0, 0, 1}, epmd_port: 0}
    )

    :ok = Cluster.set_mode(:open)
    :ok = Cluster.configure_open("operator", @cookie)
    :ok = Cluster.enable()
    :ok
  end

  # A stock node (registered with this machine's epmd) on `cookie`.
  defp peer(cookie, extra \\ []) do
    name = :"remote#{System.unique_integer([:positive])}"

    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", String.to_charlist(cookie) | extra]
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    {peer, node}
  end

  defp entry(node), do: Enum.find(Cluster.status().peers, &(&1.node == Atom.to_string(node)))

  test "connects to a stock node with its cookie; forgetting it revokes that cookie" do
    assert %{running: true, mode: :open, node: :"operator@127.0.0.1"} = Cluster.status()
    {peer, node} = peer("remotecookie")
    name = Atom.to_string(node)

    assert {:error, :refused} = Cluster.connect(name, "wrongcookie")
    assert :ok = Cluster.connect(name, "remotecookie")
    assert %{connected: true, saved: true} = entry(node)
    assert :erpc.call(node, :erlang, :node, []) == node

    :ok = Cluster.subscribe()
    assert :ok = Cluster.disconnect(name)
    assert_receive {:operator_cluster, :changed}
    refute entry(node)
    # Its cookie no longer opens a link, from either side.
    assert :erlang.get_cookie(node) == String.to_atom(@cookie)
    refute Node.connect(node)
    refute :peer.call(peer, :net_kernel, :connect_node, [:"operator@127.0.0.1"])
  end

  test "a node going away shows at once" do
    {peer, node} = peer(@cookie)
    assert :ok = Cluster.connect(Atom.to_string(node), nil)
    :ok = Cluster.subscribe()
    :peer.stop(peer)
    assert_receive {:operator_cluster, :changed}, 5_000
    assert %{connected: false, saved: true} = entry(node)
  end

  test "a hidden node counts as connected" do
    {_peer, node} = peer(@cookie, [~c"-hidden"])
    assert :ok = Cluster.connect(Atom.to_string(node), nil)
    assert %{connected: true} = entry(node)
  end

  test "a new cookie drops links made on the old one, not those with their own" do
    {_shared, on_ours} = peer(@cookie)
    {_own, on_theirs} = peer("theirs")
    assert :ok = Cluster.connect(Atom.to_string(on_ours), nil)
    assert :ok = Cluster.connect(Atom.to_string(on_theirs), "theirs")

    assert :ok = Cluster.configure_open("operator", "newcookie")
    refute on_ours in Node.list(:connected)
    assert on_theirs in Node.list(:connected)
    # Redialled with the new cookie, which that node doesn't have.
    Process.sleep(200)
    assert %{connected: false} = entry(on_ours)
  end

  test "past 64 remembered nodes, the oldest is forgotten with its cookie" do
    nodes = for i <- 1..65, do: "gone#{i}_#{System.unique_integer([:positive])}@127.0.0.1"

    for node <- nodes,
        do: assert({:error, {:not_registered, _}} = Cluster.connect(node, "c#{node}"))

    [oldest | kept] = nodes
    refute entry(String.to_atom(oldest))
    assert Enum.count(Cluster.status().peers) == 64
    assert :erlang.get_cookie(String.to_atom(oldest)) == String.to_atom(@cookie)
    assert :erlang.get_cookie(String.to_atom(hd(kept))) == String.to_atom("c" <> hd(kept))
  end
end
