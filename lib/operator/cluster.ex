defmodule Operator.Cluster do
  @moduledoc """
  Operator's Erlang cluster: phones (and Nerves devices, Macs) joined over
  mutually authenticated TLS distribution on the local network. Off by
  default; [menu] › cluster (`Operator.ClusterScreen`) turns it on, pairs
  and shows the peers. docs/CLUSTER.md has the whole design and the recipe
  for a node that isn't a phone.

  ## Distribution modes

  The BEAM boots with `-proto_dist operator` (`:operator_dist`), the one
  thing OTP reads only from the command line (net_kernel picks the carrier
  module from it). The native hosts write it to `Mob.InitArgs`' file
  before the first launch and this process keeps it there, so no launch
  needs a restart. Everything else is set at run time when cluster
  distribution starts (`prepare_node/0`): the TLS options and global's
  `connect_all`; then the cookie. Distribution then
  runs in one of two modes, never both:

    * off (the default): development builds keep `Mob.Dist`'s link, plain
      TCP on loopback, reached from the Mac over `adb forward` (`mix
      mob.connect`, scripts/rpc.sh); release builds have no distribution at
      all. Nothing listens on the network.
    * on: the node is `operator_<id>@<Wi-Fi address>` (`Operator.Cluster.Identity`),
      TLS 1.3 on that address only, port #{9370}, no epmd (`:operator_epmd`),
      peers checked against pinned certificate fingerprints
      (`Operator.Cluster.Tls`). The development link is replaced: from the
      Mac, join the cluster instead (scripts/cluster_rpc.sh).

  ## Pairing and membership

  `invite/0` opens a pairing window (#{5} minutes) with a fresh secret and
  returns the link (`Operator.Cluster.Invite`) the screen shows as a QR.
  The other side confirms it with the screen lock, then `join/1`: it pins
  the inviter, takes its cookie, turns the cluster on and connects. The
  inviter lets the unpinned certificate through only because the window is
  open, and pins it once the peer has passed the cookie and said (`hello`)
  which fingerprint is its own, with that window's secret: the cookie alone
  doesn't bring back a forgotten member. Members tell each other the peers
  they pinned (introduced trust: every member can already run code on every
  other one) and revocations (`forget/1`), which are never undone by
  gossip. At most #{32} members and #{64} identities (members and
  revocations) are kept. `reset/0` forgets everything and makes a new
  cookie.

  State: `<data dir>/cluster/cluster.json` (on/off, peers; no secret), the
  cookie and the key in the secure store.

  ## For code that runs on the cluster

  Front (Dyn) screens and the agent use `Operator.Cluster.Bus` (peers,
  publish/subscribe on topics, calling a named service on a peer): it only
  reaches processes that joined its `:pg` scope, never `:rpc`.
  """
  use GenServer

  alias Operator.Cluster.Identity
  alias Operator.Cluster.Invite
  alias Operator.Cluster.Tls

  require Logger

  @port 9370
  @window_ms 5 * 60_000
  @reconnect_ms 30_000
  @start_delay_ms 3_000
  @max_peers 32
  @max_identities 64
  @cookie_account "cluster_cookie"
  @join_account "cluster_join"
  @dev_node :"operator_android@127.0.0.1"
  @pg_scope :operator_cluster

  @type peer :: %{
          fingerprint: String.t(),
          node: String.t(),
          revoked: boolean(),
          connected: boolean()
        }

  # ── API ──

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  @doc """
  Starts the cluster process. Options: `:dir` (state dir, default
  `<data dir>/cluster`), `:boot_dist` (default true on a phone: start
  distribution in the saved mode after #{@start_delay_ms} ms, the delay
  `Mob.Dist` uses), `:dev_node` (the development link's node name),
  `:address` (listen on this IPv4 address instead of the LAN one: tests).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The fixed distribution port of every cluster node."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc "The `:pg` scope `Operator.Cluster.Bus` uses."
  @spec pg_scope() :: atom()
  def pg_scope, do: @pg_scope

  @doc """
  What the cluster screen shows: `enabled` (saved setting), `running` (TLS
  distribution up), `node`, `address`, `port`, `fingerprint` (this node's),
  `restart_needed` (this launch didn't boot with the cluster's init args:
  open Operator again), `pairing` (window open), `peers` and `error` (why
  the last start failed).
  """
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Saves the cluster as on and starts it."
  @spec enable() :: :ok | {:error, term()}
  def enable, do: GenServer.call(__MODULE__, :enable, 30_000)

  @doc "Saves the cluster as off, stops it and brings the development link back."
  @spec disable() :: :ok
  def disable, do: GenServer.call(__MODULE__, :disable, 30_000)

  @doc "Opens the pairing window and returns this node's invite link."
  @spec invite() :: {:ok, String.t()} | {:error, :not_running}
  def invite, do: GenServer.call(__MODULE__, :invite)

  @doc "Closes the pairing window."
  @spec close_pairing() :: :ok
  def close_pairing, do: GenServer.call(__MODULE__, :close_pairing)

  @doc """
  Accepts an invite the human confirmed with the screen lock: pins the
  inviter, takes its cookie, turns the cluster on and connects to it.
  """
  @spec join(Invite.t()) :: :ok | {:error, term()}
  def join(%{node: _, fingerprint: _, cookie: _, port: _} = invite),
    do: GenServer.call(__MODULE__, {:join, invite}, 30_000)

  @doc "Revokes a peer here and on every member reachable now (and later, by gossip)."
  @spec forget(String.t()) :: :ok
  def forget(fingerprint), do: GenServer.call(__MODULE__, {:forget, fingerprint})

  @doc """
  Turns the cluster off and forgets it: every peer, the cookie, and this
  node's identity (a new name and fingerprint next time).
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset, 30_000)

  @doc "Messages `{:operator_cluster, :changed}` to the caller on every change."
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc """
  Whether this launch booted with `-proto_dist operator`. Only a build from
  before the native hosts wrote it lacks it on its first launch.
  """
  @spec booted_for_cluster?() :: boolean()
  def booted_for_cluster?, do: :init.get_argument(:proto_dist) == {:ok, [[~c"operator"]]}

  @doc """
  Gets a node ready to start cluster distribution: `inet_tls_dist`'s
  options, and `global` told not to mesh every node it hears of (each
  node connects to the members it pinned; global's default would drop
  working links to a member that doesn't pin everyone, a headless device,
  "to prevent overlapping partitions"). global reads `connect_all` when it
  starts, which is at boot, so it is restarted with the new setting; only
  while distribution is off, where it holds nothing.
  """
  @spec prepare_node() :: :ok
  def prepare_node do
    :ok = Tls.install_dist_options()
    limit_global()
  end

  defp limit_global do
    if Application.get_env(:kernel, :connect_all) != false and not Node.alive?() do
      Application.put_env(:kernel, :connect_all, false)
      :ok = Supervisor.terminate_child(:kernel_sup, :global_name_server)
      {:ok, _} = Supervisor.restart_child(:kernel_sup, :global_name_server)
    end

    :ok
  end

  @doc "The phone's Wi-Fi (or other private LAN) IPv4 address."
  @spec lan_address() :: {:ok, :inet.ip4_address()} | {:error, :no_network}
  def lan_address do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         [ip | _] <- for({_, opts} <- ifaddrs, {:addr, ip} <- opts, private?(ip), do: ip) do
      {:ok, ip}
    else
      _ -> route_address()
    end
  end

  # The address the default route leaves from (a UDP connect sends nothing).
  defp route_address do
    with {:ok, socket} <- :gen_udp.open(0, [:inet]) do
      result =
        with :ok <- :gen_udp.connect(socket, {192, 168, 0, 1}, 9),
             {:ok, {ip, _}} <- :inet.sockname(socket),
             true <- private?(ip) do
          {:ok, ip}
        else
          _ -> {:error, :no_network}
        end

      :gen_udp.close(socket)
      result
    end
  end

  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?(_ip), do: false

  # ── server ──

  @impl true
  def init(opts) do
    phone? = System.get_env("MOB_BEAMS_DIR") != nil
    dir = Keyword.get_lazy(opts, :dir, fn -> Path.join(Operator.Paths.data_dir(), "cluster") end)
    File.mkdir_p!(dir)
    :ok = Tls.init_table()
    # Linked: restarted along with this process. Local-only while off.
    {:ok, _} = :pg.start_link(@pg_scope)
    if phone?, do: write_init_args()

    saved = read_state(dir)

    s = %{
      dir: dir,
      enabled: saved.enabled,
      peers: saved.peers,
      running: false,
      node: nil,
      address: nil,
      fingerprint: nil,
      window_until: nil,
      window_secret: nil,
      # Survives the restart a join usually needs (the first launch with
      # the cluster's init args), until the inviter's window would close.
      join_secret: stored_join_secret(),
      error: nil,
      subscribers: MapSet.new(),
      dev_node: Keyword.get(opts, :dev_node, @dev_node),
      fixed_address: Keyword.get(opts, :address)
    }

    sync_pins(s)

    if Keyword.get(opts, :boot_dist, phone?),
      do: Process.send_after(self(), :boot_dist, @start_delay_ms)

    {:ok, s}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, status_map(s), s}

  def handle_call(:enable, _from, s) do
    s = %{s | enabled: true}
    save(s)

    case start_cluster(s) do
      {:ok, s} -> {:reply, :ok, changed(s)}
      {:error, reason, s} -> {:reply, {:error, reason}, changed(recover(s, reason))}
    end
  end

  def handle_call(:disable, _from, s) do
    s = %{s | enabled: false} |> stop_cluster() |> close_window()
    save(s)
    start_dev_link(s)
    {:reply, :ok, changed(s)}
  end

  def handle_call(:invite, _from, %{running: false} = s), do: {:reply, {:error, :not_running}, s}

  def handle_call(:invite, _from, s) do
    # A fresh cookie per invite, given to every member connected now: an
    # earlier QR (and the cookie in it) can't open distribution in this or
    # a later window. A member offline meanwhile rejoins with a new invite.
    {:ok, cookie} = rotate_cookie(s)
    broadcast({:cookie, cookie})
    until = System.monotonic_time(:millisecond) + @window_ms
    secret = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ok = Tls.open_window(until)
    Process.send_after(self(), :window_check, @window_ms + 100)

    link =
      Invite.link(%{
        node: Atom.to_string(s.node),
        fingerprint: s.fingerprint,
        cookie: cookie,
        secret: secret,
        port: @port
      })

    {:reply, {:ok, link}, changed(%{s | window_until: until, window_secret: secret})}
  end

  def handle_call(:close_pairing, _from, s), do: {:reply, :ok, changed(close_window(s))}

  def handle_call({:join, invite}, _from, s) do
    with :ok <- admissible_invite(s, invite),
         :ok <- same_port(invite.port),
         :ok <- adopt_cookie(s, invite) do
      s = pin(s, invite.fingerprint, invite.node)
      s = %{s | enabled: true, join_secret: invite.secret}
      store_join_secret(invite.secret)
      save(s)
      complete_join(s, invite)
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  # The forgotten peer kept the cookie, which would still get it through
  # distribution's handshake (and with that, everything) while any later
  # pairing window is open: the cookie is replaced, here and on every member
  # reachable now. A member offline meanwhile rejoins with a new invite.
  def handle_call({:forget, fingerprint}, _from, s) do
    s = revoke(s, fingerprint)
    broadcast({:revoke, fingerprint})

    with {:ok, cookie} <- rotate_cookie(s), do: broadcast({:cookie, cookie})

    {:reply, :ok, changed(s)}
  end

  def handle_call(:reset, _from, s) do
    s = s |> stop_cluster() |> close_window()
    _ = Operator.SecureStore.delete(@cookie_account)
    _ = Operator.SecureStore.delete(@join_account)
    _ = Identity.delete()
    s = %{s | enabled: false, peers: [], fingerprint: nil, error: nil, join_secret: nil}
    save(s)
    sync_pins(s)
    start_dev_link(s)
    {:reply, :ok, changed(s)}
  end

  def handle_call({:subscribe, pid}, _from, s) do
    Process.monitor(pid)
    {:reply, :ok, %{s | subscribers: MapSet.put(s.subscribers, pid)}}
  end

  defp complete_join(s, invite) do
    case if(s.running, do: {:ok, s}, else: start_cluster(s)) do
      {:ok, s} ->
        Node.set_cookie(String.to_atom(invite.cookie))
        connect_async(String.to_atom(invite.node), true)
        {:reply, :ok, changed(s)}

      {:error, reason, s} ->
        {:reply, {:error, reason}, changed(s)}
    end
  end

  # A peer says who it is and whom it trusts (after nodeup, both ways).
  @impl true
  def handle_cast({:hello, node, fingerprint, peers, secret}, s) when is_atom(node) do
    {:noreply, changed(hello(s, node, fingerprint, peers, secret))}
  end

  def handle_cast({:pins, from, peers}, s) when is_atom(from) do
    if member?(s, from), do: {:noreply, changed(merge(s, peers))}, else: {:noreply, s}
  end

  def handle_cast({:revoke, from, fingerprint}, s) when is_atom(from) do
    if member?(s, from) and fingerprint != s.fingerprint,
      do: {:noreply, changed(revoke(s, fingerprint))},
      else: {:noreply, s}
  end

  def handle_cast({:cookie, from, cookie}, s) when is_atom(from) and is_binary(cookie) do
    if member?(s, from) and Regex.match?(~r/\A[A-Za-z0-9_-]{16,128}\z/, cookie),
      do: take_cookie(s, cookie)

    {:noreply, s}
  end

  def handle_cast(_other, s), do: {:noreply, s}

  @impl true
  def handle_info(:boot_dist, %{enabled: true} = s) do
    case start_cluster(s) do
      {:ok, s} -> {:noreply, changed(s)}
      {:error, reason, s} -> {:noreply, changed(recover(s, reason))}
    end
  end

  def handle_info(:boot_dist, s) do
    start_dev_link(s)
    {:noreply, s}
  end

  def handle_info({:nodeup, node, _info}, %{running: true} = s) do
    Logger.info("[cluster] linked to #{node}#{if s.join_secret, do: " (joining)", else: ""}")
    say_hello(s, node)
    {:noreply, changed(s)}
  end

  def handle_info({:nodedown, _node, _info}, s), do: {:noreply, changed(s)}

  def handle_info(:reconnect, %{running: true} = s) do
    s = check_address(s)

    for %{node: node, revoked: false} <- s.peers,
        node = String.to_atom(node),
        node != Node.self() and node not in Node.list(),
        do: connect_async(node, s.join_secret != nil)

    # Still joining: say hello again on every link. The first one can be
    # lost (an iPhone suspended right after the connection came up), and
    # the inviter pins only on a hello with its window's secret.
    if s.join_secret, do: Enum.each(Node.list(), &say_hello(s, &1))

    Process.send_after(self(), :reconnect, @reconnect_ms)
    {:noreply, s}
  end

  def handle_info(:window_check, s) do
    if s.window_until && System.monotonic_time(:millisecond) >= s.window_until,
      do: {:noreply, changed(close_window(s))},
      else: {:noreply, s}
  end

  def handle_info({:join_expired, secret}, %{join_secret: secret} = s) do
    _ = Operator.SecureStore.delete(@join_account)
    {:noreply, %{s | join_secret: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, s),
    do: {:noreply, %{s | subscribers: MapSet.delete(s.subscribers, pid)}}

  def handle_info(_other, s), do: {:noreply, s}

  # ── starting and stopping ──

  # A start that failed: the development link comes back (a development
  # build), and unless only another launch can fix it, another try later
  # (no Wi-Fi yet, the port taken, ...) while the cluster stays enabled.
  defp recover(s, reason) do
    start_dev_link(s)
    if reason != :restart_needed, do: Process.send_after(self(), :boot_dist, @reconnect_ms)
    s
  end

  defp start_cluster(%{running: true} = s), do: {:ok, s}

  defp start_cluster(s) do
    with :ok <- booted(),
         {:ok, ip} <- address(s),
         {:ok, identity} <- Identity.load_or_create(),
         {:ok, cookie} <- cookie(),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok = stop_dist()
      :ok = prepare_node()
      node = :"#{Identity.name(identity)}@#{:inet.ntoa(ip)}"
      :ok = :operator_dist.set_mode(:tls)
      Application.put_env(:kernel, :epmd_module, :operator_epmd)
      Application.put_env(:kernel, :operator_dist_port, @port)
      Application.put_env(:kernel, :inet_dist_use_interface, ip)

      case Node.start(node, :longnames) do
        {:ok, _} ->
          Node.set_cookie(String.to_atom(cookie))
          :ok = :net_kernel.monitor_nodes(true)
          Process.send_after(self(), :reconnect, 0)
          Logger.info("[cluster] up as #{node}")

          {:ok,
           %{
             s
             | running: true,
               node: node,
               address: ip,
               fingerprint: identity.fingerprint,
               error: nil
           }}

        {:error, reason} ->
          tls_off()
          failed(s, {:dist, reason})
      end
    else
      {:error, reason} -> failed(s, reason)
    end
  end

  # The development link has to go before cluster distribution starts. On
  # Android mob starts it at run time (`Mob.Dist`); an iOS development build
  # starts it from the command line (`-name`), which `net_kernel:stop/0`
  # refuses to stop: then kernel's boot-time `net_sup` child is removed by
  # hand, after which `Node.start/2` adds its own as for any runtime start.
  defp stop_dist do
    Mob.Dist.stop()

    if Node.alive?() do
      :ok = Supervisor.terminate_child(:kernel_sup, :net_sup)
      :ok = Supervisor.delete_child(:kernel_sup, :net_sup)
    end

    :ok
  end

  defp failed(s, reason) do
    Logger.warning("[cluster] not started: #{inspect(reason)}")
    {:error, reason, %{s | error: reason}}
  end

  defp booted,
    do: if(booted_for_cluster?(), do: :ok, else: {:error, :restart_needed})

  defp stop_cluster(%{running: false} = s), do: s

  defp stop_cluster(s) do
    :net_kernel.monitor_nodes(false)
    Mob.Dist.stop()
    tls_off()
    Logger.info("[cluster] stopped")
    %{s | running: false, node: nil, address: nil}
  end

  defp tls_off do
    :ok = :operator_dist.set_mode(:tcp)
    Application.delete_env(:kernel, :epmd_module)
    Application.delete_env(:kernel, :operator_dist_port)
    Application.delete_env(:kernel, :inet_dist_use_interface)
  end

  # Development builds: the loopback link mob_dev reaches over adb. Release
  # builds: Mob.Dist waits for an epmd that never comes, and gives up.
  defp start_dev_link(s) do
    if System.get_env("MOB_BEAMS_DIR"), do: Mob.Dist.ensure_started(node: s.dev_node, delay: 0)
    true
  end

  defp address(%{fixed_address: nil}), do: lan_address()
  defp address(%{fixed_address: ip}), do: {:ok, ip}

  # A new Wi-Fi address means a new node name: restart on it.
  defp check_address(s) do
    case address(s) do
      {:ok, ip} when ip != s.address ->
        Logger.info("[cluster] address changed to #{:inet.ntoa(ip)}: restarting")

        case start_cluster(stop_cluster(s)) do
          {:ok, s} -> changed(s)
          {:error, _, s} -> changed(s)
        end

      _ ->
        s
    end
  end

  # While joining, someone is watching the screen: say why a link failed
  # (the reconnect loop retries quietly the rest of the time).
  defp connect_async(node, joining?) do
    spawn(fn ->
      with :ok <- reachable(node),
           true <- Node.connect(node) do
        :ok
      else
        failed -> joining? && Logger.warning("[cluster] can't reach #{node}: #{failed}")
      end
    end)
  end

  # Distribution only dials once the peer's port answers. A dial that can't
  # arrive (the peer is on a network that reaches us but not the other way
  # round) stays pending, and while it does, the node with the greater name
  # turns away the peer's own dial without an error: two phones that each
  # retry would then never link.
  defp reachable(node) do
    [_name, host] = node |> Atom.to_string() |> String.split("@", parts: 2)

    with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
         {:ok, socket} <- :gen_tcp.connect(ip, @port, [], 3_000) do
      :gen_tcp.close(socket)
    else
      {:error, :einval} -> :ok
      {:error, reason} -> reason
    end
  end

  # Who this node is and whom it trusts; with the pairing secret while joining.
  defp say_hello(s, node) do
    hello = {:hello, Node.self(), s.fingerprint, wire_peers(s), s.join_secret}
    GenServer.cast({__MODULE__, node}, hello)
  end

  # ── pinning ──

  defp hello(s, node, fingerprint, peers, secret)
       when is_binary(fingerprint) and is_list(peers) do
    cond do
      revoked?(s, fingerprint) ->
        Node.disconnect(node)
        s

      pinned?(s, fingerprint) ->
        s |> rename(fingerprint, Atom.to_string(node)) |> merge(peers)

      window_secret?(s, secret) and Tls.take_pending(fingerprint) ->
        admit(s, node, fingerprint, peers)

      true ->
        # Connected without a pinned certificate, or a pending one without
        # this window's secret: not ours.
        Logger.warning("[cluster] #{node} isn't a member: #{not_admitted(s, secret)}")
        Node.disconnect(node)
        s
    end
  end

  defp hello(s, _node, _fingerprint, _peers, _secret), do: s

  defp not_admitted(%{window_secret: nil}, _secret), do: "no pairing window is open"
  defp not_admitted(_s, nil), do: "it sent no pairing secret"

  defp not_admitted(s, secret) do
    if window_secret?(s, secret),
      do: "its certificate wasn't presented in this pairing window",
      else: "its pairing secret is from another invite"
  end

  defp admit(s, node, fingerprint, peers) do
    s = pin(s, fingerprint, Atom.to_string(node))

    if pinned?(s, fingerprint) do
      Logger.info("[cluster] paired with #{node}")
      broadcast_pins(s)
      merge(s, peers)
    else
      Logger.warning("[cluster] refused #{node}: the cluster is full")
      Node.disconnect(node)
      s
    end
  end

  defp window_secret?(%{window_secret: expected}, secret)
       when is_binary(expected) and is_binary(secret) and
              byte_size(expected) == byte_size(secret),
       do: :crypto.hash_equals(expected, secret)

  defp window_secret?(_s, _secret), do: false

  defp member?(s, node),
    do: Enum.any?(s.peers, &(&1.node == Atom.to_string(node) and not &1.revoked))

  # Peers a member introduces; never resurrects a revoked one. Revocations of
  # identities this node never knew are kept while there's room.
  defp merge(s, peers) when is_list(peers) do
    Enum.reduce(peers, s, fn
      %{fingerprint: fp, node: node, revoked: true}, acc when is_binary(fp) and is_binary(node) ->
        cond do
          fp == acc.fingerprint -> acc
          known?(acc, fp) or length(acc.peers) < @max_identities -> revoke(acc, fp, node)
          true -> acc
        end

      %{fingerprint: fp, node: node}, acc when is_binary(fp) and is_binary(node) ->
        if fp == acc.fingerprint or known?(acc, fp), do: acc, else: pin(acc, fp, node)

      _, acc ->
        acc
    end)
  end

  defp merge(s, _peers), do: s

  defp pin(s, fingerprint, node) do
    cond do
      revoked?(s, fingerprint) ->
        s

      known?(s, fingerprint) ->
        rename(s, fingerprint, node)

      Enum.count(s.peers, &(not &1.revoked)) >= @max_peers or
          length(s.peers) >= @max_identities ->
        s

      true ->
        peers = s.peers ++ [%{fingerprint: fingerprint, node: node, revoked: false}]
        s = %{s | peers: peers}
        save(s)
        sync_pins(s)
        s
    end
  end

  defp rename(s, fingerprint, node) do
    peers =
      Enum.map(s.peers, fn
        %{fingerprint: ^fingerprint} = peer -> %{peer | node: node}
        peer -> peer
      end)

    s = %{s | peers: peers}
    save(s)
    s
  end

  defp revoke(s, fingerprint, node \\ nil) do
    old = Enum.find(s.peers, &(&1.fingerprint == fingerprint))
    node = (old && old.node) || node || ""

    peers =
      Enum.reject(s.peers, &(&1.fingerprint == fingerprint)) ++
        [%{fingerprint: fingerprint, node: node, revoked: true}]

    s = %{s | peers: peers}
    save(s)
    sync_pins(s)
    if node != "", do: disconnect(node)
    s
  end

  defp known?(s, fp), do: Enum.any?(s.peers, &(&1.fingerprint == fp))
  defp pinned?(s, fp), do: Enum.any?(s.peers, &(&1.fingerprint == fp and not &1.revoked))
  defp revoked?(s, fp), do: Enum.any?(s.peers, &(&1.fingerprint == fp and &1.revoked))

  # Never creates an atom from a name a peer gossiped.
  defp disconnect(node) do
    Node.disconnect(String.to_existing_atom(node))
  rescue
    ArgumentError -> false
  end

  defp sync_pins(s) do
    {revoked, pinned} = Enum.split_with(s.peers, & &1.revoked)
    Tls.put_pins(Enum.map(pinned, & &1.fingerprint), Enum.map(revoked, & &1.fingerprint))
  end

  defp broadcast_pins(s), do: broadcast({:pins, wire_peers(s)})

  defp broadcast(message) do
    for node <- Node.list() do
      GenServer.cast({__MODULE__, node}, Tuple.insert_at(message, 1, Node.self()))
    end

    :ok
  end

  defp wire_peers(s), do: Enum.map(s.peers, &Map.take(&1, [:fingerprint, :node, :revoked]))

  defp close_window(s) do
    Tls.close_window()
    %{s | window_until: nil, window_secret: nil}
  end

  # ── cookie ──

  defp cookie do
    case Operator.SecureStore.get(@cookie_account) do
      {:ok, cookie} when is_binary(cookie) ->
        {:ok, cookie}

      {:ok, nil} ->
        cookie = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        with :ok <- Operator.SecureStore.put(@cookie_account, cookie), do: {:ok, cookie}

      {:error, _} = error ->
        error
    end
  end

  # "<unix expiry>:<secret>" in the secure store; schedules its own expiry.
  defp store_join_secret(secret) do
    expires = System.os_time(:second) + div(@window_ms, 1000)
    _ = Operator.SecureStore.put(@join_account, "#{expires}:#{secret}")
    Process.send_after(self(), {:join_expired, secret}, @window_ms)
  end

  defp stored_join_secret do
    with {:ok, value} when is_binary(value) <- Operator.SecureStore.get(@join_account),
         [expires, secret] <- String.split(value, ":", parts: 2),
         {expires, ""} <- Integer.parse(expires),
         left when left > 0 <- expires - System.os_time(:second) do
      Process.send_after(self(), {:join_expired, secret}, left * 1000)
      secret
    else
      _ ->
        _ = Operator.SecureStore.delete(@join_account)
        nil
    end
  end

  defp rotate_cookie(s),
    do: take_cookie(s, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

  defp take_cookie(s, cookie) do
    case Operator.SecureStore.put(@cookie_account, cookie) do
      :ok ->
        if s.running, do: Node.set_cookie(String.to_atom(cookie))
        {:ok, cookie}

      {:error, reason} = error ->
        Logger.error("[cluster] cookie not stored: #{inspect(reason)}")
        error
    end
  end

  defp admissible_invite(s, invite) do
    cond do
      revoked?(s, invite.fingerprint) ->
        {:error, :revoked}

      known?(s, invite.fingerprint) ->
        :ok

      Enum.count(s.peers, &(not &1.revoked)) >= @max_peers or
          length(s.peers) >= @max_identities ->
        {:error, :peer_limit}

      true ->
        :ok
    end
  end

  # A member that missed a cookie change (it was offline when a peer was
  # forgotten) takes the new one from an invite of a member it has pinned.
  defp adopt_cookie(s, %{cookie: new_cookie, fingerprint: inviter}) do
    case Operator.SecureStore.get(@cookie_account) do
      {:ok, nil} ->
        Operator.SecureStore.put(@cookie_account, new_cookie)

      {:ok, ^new_cookie} ->
        :ok

      {:ok, _other} when s.peers == [] ->
        Operator.SecureStore.put(@cookie_account, new_cookie)

      {:ok, _other} ->
        if pinned?(s, inviter),
          do: Operator.SecureStore.put(@cookie_account, new_cookie),
          else: {:error, :different_cluster}

      {:error, _} = error ->
        error
    end
  end

  defp same_port(@port), do: :ok
  defp same_port(_other), do: {:error, :other_port}

  # ── state ──

  # The native hosts write the same before the first launch (MainActivity,
  # AppDelegate); this keeps it so after an app update or a reset.
  defp write_init_args do
    args = ["-proto_dist", "operator"]

    if Mob.InitArgs.read() != args do
      case Mob.InitArgs.write(args) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[cluster] init args not written: #{inspect(reason)}")
      end
    end
  end

  defp read_state(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "cluster.json")),
         {:ok, %{"enabled" => enabled, "peers" => peers}} when is_boolean(enabled) <-
           JSON.decode(json) do
      %{enabled: enabled, peers: Enum.flat_map(peers, &read_peer/1)}
    else
      _ -> %{enabled: false, peers: []}
    end
  end

  defp read_peer(%{"fingerprint" => fp, "node" => node, "revoked" => revoked})
       when is_binary(fp) and is_binary(node) and is_boolean(revoked),
       do: [%{fingerprint: fp, node: node, revoked: revoked}]

  defp read_peer(_other), do: []

  defp save(s) do
    json = JSON.encode!(%{enabled: s.enabled, peers: s.peers})
    path = Path.join(s.dir, "cluster.json")
    :ok = File.write(path <> ".tmp", json)
    :ok = File.rename(path <> ".tmp", path)
  end

  defp status_map(s) do
    connected = Enum.map(Node.list(), &Atom.to_string/1)

    %{
      enabled: s.enabled,
      running: s.running,
      node: s.node,
      address: s.address && to_string(:inet.ntoa(s.address)),
      port: @port,
      fingerprint: s.fingerprint || stored_fingerprint(),
      restart_needed: not booted_for_cluster?(),
      pairing: s.window_until != nil,
      error: s.error,
      peers:
        for peer <- s.peers do
          Map.put(peer, :connected, s.running and peer.node in connected)
        end
    }
  end

  defp stored_fingerprint do
    case Identity.load() do
      {:ok, identity} -> identity.fingerprint
      _ -> nil
    end
  end

  defp changed(s) do
    for pid <- s.subscribers, do: send(pid, {:operator_cluster, :changed})
    s
  end
end
