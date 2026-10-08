defmodule Operator.Cluster.Tls do
  @moduledoc """
  The TLS side of the cluster: the options `inet_tls_dist` runs with, and
  the certificate check that pins peers by fingerprint.

  The BEAM boots with `-proto_dist operator` only (`Operator.Cluster`
  writes it with `Mob.InitArgs`; the native hosts write it before the very
  first launch). Nothing else has to be decided at boot: before cluster
  distribution starts, `install_dist_options/0` gives `inet_tls_dist` its
  options at run time, in the `ssl_dist_opts` table it reads (what
  `-ssl_dist_optfile` would otherwise fill), from `dist_options/0`, which
  reads the key from the secure store (`Operator.Cluster.Identity`). Both
  directions are TLS 1.3 with a client certificate required.

  ## Who is let in

  `verify/3` is the `verify_fun` of both sides. Every certificate the peer
  presents must have a pinned fingerprint (the peer's own self-signed one;
  a chain through anything else fails), except while a pairing window is
  open (`open_window/1`): then the listening side lets an unpinned
  certificate through and remembers its fingerprint as pending. The peer
  must still pass the distribution cookie, which only an invite shows; it
  is pinned only once it has (`Operator.Cluster` asks it for its
  fingerprint after `nodeup` and pins it if it is pending). A revoked
  fingerprint is refused even in a window. Without the table (the cluster
  process isn't running) everything is refused.

  The table is public for reads by the TLS connection processes; it is
  owned and written by `Operator.Cluster`.
  """

  alias Operator.Cluster.Identity

  require Logger

  @table __MODULE__

  @doc "Creates the table (owned by the caller, `Operator.Cluster`)."
  @spec init_table() :: :ok
  def init_table do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc "Replaces the pinned and revoked fingerprints."
  @spec put_pins([String.t()], [String.t()]) :: :ok
  def put_pins(pinned, revoked) do
    :ets.match_delete(@table, {{:pin, :_}, :_})
    :ets.insert(@table, Enum.map(pinned, &{{:pin, &1}, :pinned}))
    :ets.insert(@table, Enum.map(revoked, &{{:pin, &1}, :revoked}))
    :ok
  end

  @doc "Lets unpinned peers connect in (as pending) until `deadline` (monotonic ms)."
  @spec open_window(integer()) :: :ok
  def open_window(deadline) do
    :ets.insert(@table, {:window, deadline})
    :ok
  end

  @doc "Closes the pairing window and drops what it saw."
  @spec close_window() :: :ok
  def close_window do
    :ets.delete(@table, :window)
    :ets.match_delete(@table, {{:pending, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Is the pairing window open?"
  @spec window_open?() :: boolean()
  def window_open? do
    case lookup(:window) do
      [{:window, deadline}] -> System.monotonic_time(:millisecond) < deadline
      _ -> false
    end
  end

  @doc "Did a peer present this fingerprint while the window was open? Consumes it."
  @spec take_pending(String.t()) :: boolean()
  def take_pending(fingerprint) do
    match?([_ | _], :ets.take(@table, {:pending, fingerprint}))
  rescue
    ArgumentError -> false
  end

  @doc """
  The `verify_fun` for both sides (`role` is `:server` or `:client`): see
  the moduledoc.
  """
  @spec verify(term(), term(), :server | :client) ::
          {:valid, atom()} | {:fail, term()} | {:unknown, atom()}
  def verify(_cert, {:extension, _}, role), do: {:unknown, role}

  # These identities are deliberately self-signed: pinning the exact
  # certificate fingerprint is the trust decision.
  def verify(cert, event, role)
      when event in [:valid, :valid_peer, {:bad_cert, :selfsigned_peer}] do
    fingerprint =
      :OTPCertificate
      |> :public_key.pkix_encode(cert, :otp)
      |> Identity.fingerprint()

    case lookup({:pin, fingerprint}) do
      [{_, :pinned}] ->
        {:valid, role}

      [{_, :revoked}] ->
        refuse(fingerprint, :revoked)

      _ ->
        if role == :server and window_open?() do
          :ets.insert(@table, {{:pending, fingerprint}, true})
          Logger.info("[cluster] pairing: unpinned peer #{short(fingerprint)} let in")
          {:valid, role}
        else
          refuse(fingerprint, :not_pinned)
        end
    end
  end

  def verify(_cert, {:bad_cert, reason}, _role), do: {:fail, reason}
  def verify(_cert, event, _role), do: {:fail, {:unsupported_certificate_event, event}}

  defp refuse(fingerprint, why) do
    Logger.warning("[cluster] refused peer #{short(fingerprint)}: #{why}")
    {:fail, {why, fingerprint}}
  end

  defp short(fingerprint), do: binary_part(fingerprint, 0, 16)

  # No table: the cluster isn't running, so nothing is trusted.
  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  @doc """
  The options for `inet_tls_dist`: this node's certificate and key, TLS
  1.3, peer certificates required both ways and checked by `verify/3`.
  `cacerts` is only there because `verify_peer` needs a trust store; it
  holds this node's own certificate, which no peer can present without
  this node's key. (Also what the `ssl_dist.conf` optfile of 1.1.0 builds
  calls back.)
  """
  @spec dist_options() :: [{:server | :client, keyword()}]
  def dist_options do
    {:ok, %Identity{cert: cert, key: key}} = Identity.load()
    key_der = :public_key.der_encode(:ECPrivateKey, key)

    common = [
      cert: cert,
      key: {:ECPrivateKey, key_der},
      cacerts: [cert],
      versions: [:"tlsv1.3"],
      verify: :verify_peer
    ]

    [
      server: common ++ [fail_if_no_peer_cert: true, verify_fun: {&verify/3, :server}],
      client: common ++ [server_name_indication: :disable, verify_fun: {&verify/3, :client}]
    ]
  end

  @dist_table :ssl_dist_opts

  @doc """
  Puts `dist_options/0` where `inet_tls_dist` looks for its options (the
  `ssl_dist_opts` table; the caller, `Operator.Cluster`, owns it), for the
  next connections. A node booted with `-ssl_dist_optfile` (1.1.0) has the
  table from `ssl_dist_sup`, filled through the same callback: left alone.
  """
  @spec install_dist_options() :: :ok
  def install_dist_options do
    if :init.get_argument(:ssl_dist_optfile) == :error do
      if :ets.whereis(@dist_table) == :undefined,
        do: :ets.new(@dist_table, [:named_table, :protected, :set, read_concurrency: true])

      true = :ets.insert(@dist_table, dist_options())
    end

    :ok
  end
end
