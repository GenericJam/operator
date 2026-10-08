# A headless BEAM peer for exercising the same protocol a Nerves device uses.
# See docs/CLUSTER.md. This is a development probe, not a separately supported
# package: it intentionally loads Operator's cluster modules from this checkout.

alias Operator.Cluster
alias Operator.Cluster.Bus
alias Operator.Cluster.Identity
alias Operator.Cluster.Invite
alias Operator.Cluster.Tls

args = System.argv()
dir = System.get_env("MOB_DATA_DIR") || Path.expand("../_build/cluster_peer", __DIR__)
File.mkdir_p!(dir)
# The identity and cookie stores read it.
System.put_env("MOB_DATA_DIR", dir)

unless Cluster.booted_for_cluster?() do
  IO.puts(:stderr, "This peer must boot with Operator's distribution carrier:")
  IO.puts(:stderr, ~s(  elixir --erl "-proto_dist operator" -S mix run --no-start #{__ENV__.file} <invite>))
  System.halt(2)
end

link = List.first(args) || System.get_env("OPERATOR_CLUSTER_INVITE")

invite =
  case link && Invite.parse(link) do
    {:ok, invite} -> invite
    {:error, message} -> raise message
    _ -> raise "pass an operator://cluster invite as the first argument"
  end

{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, identity} = Identity.load_or_create()
:ok = Tls.init_table()
:ok = Tls.put_pins([invite.fingerprint], [])
{:ok, _} = :pg.start_link(Cluster.pg_scope())
{:ok, address} = Cluster.lan_address()
:ok = Cluster.prepare_node()
:ok = :operator_dist.set_mode(:tls)
Application.put_env(:kernel, :epmd_module, :operator_epmd)
Application.put_env(:kernel, :operator_dist_port, Cluster.port())
Application.put_env(:kernel, :inet_dist_use_interface, address)
node = :"#{Identity.name(identity)}@#{:inet.ntoa(address)}"
{:ok, _} = Node.start(node, :longnames)
Node.set_cookie(String.to_atom(invite.cookie))
true = Process.register(self(), Cluster)
:ok = Bus.register("nerves.echo")
:net_kernel.monitor_nodes(true, node_type: :visible)

IO.puts("headless peer #{node}")
IO.puts("certificate #{identity.fingerprint}")
IO.puts("connecting to #{invite.node}:#{invite.port}")
Node.connect(String.to_atom(invite.node))

# The invite's secret goes with every hello: the inviter pins this peer's new
# certificate only with it. Like a phone, the peer pins only its inviter, so
# it talks to that one member (a two-node cluster).
hello = fn peer ->
  GenServer.cast({Cluster, peer}, {:hello, Node.self(), identity.fingerprint, [], invite.secret})
end

loop = fn loop ->
  receive do
    {:"$gen_cast", {:hello, peer, fingerprint, _peers, _secret}} ->
      IO.puts("peer #{peer} presented #{fingerprint}")
      hello.(peer)
      loop.(loop)

    {:"$gen_cast", {:pins, _peer, _peers}} ->
      loop.(loop)

    {:"$gen_cast", {:revoke, _peer, fingerprint}} ->
      IO.puts("revoked by cluster: #{fingerprint}")
      loop.(loop)

    {:cluster_call, from, request} ->
      :ok = Bus.reply(from, {:nerves_echo, request})
      loop.(loop)

    {:nodeup, peer, _info} ->
      IO.puts("connected #{peer}")
      hello.(peer)
      loop.(loop)

    {:nodedown, peer, _info} ->
      IO.puts("disconnected #{peer}")
      loop.(loop)

    other ->
      IO.puts("ignored #{inspect(other)}")
      loop.(loop)
  end
end

loop.(loop)
