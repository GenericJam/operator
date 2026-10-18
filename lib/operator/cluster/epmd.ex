defmodule Operator.Cluster.Epmd do
  @moduledoc """
  The epmd a phone doesn't have, for the open cluster mode: answers other
  nodes' lookups of this node on the LAN address, so a stock node finds it
  by name alone (`Node.connect(:"operator@10.0.0.17")`, `net_adm:names/1`).

  Only the two read-only requests of the epmd protocol
  (<https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html>):
  `PORT_PLEASE2_REQ` for this node's name (any other name: not found) and
  `NAMES_REQ`. One request per connection, as epmd does; registration
  (`ALIVE2_REQ`) is refused, so nothing else can claim a name here.

  `Operator.Cluster` opens the socket (`listen/2`) and hands it to
  `start_link/3`; the process owns it, so stopping it closes the port.
  """

  require Logger

  @port 4369
  @port_please2_req 122
  @port2_resp 119
  @names_req 110
  # Normal (not hidden) node, TCP/IPv4, distribution version 6 only.
  @node_type 77
  @protocol 0
  @dist_version 6
  @recv_timeout 5_000

  @doc "The port stock nodes ask an epmd on."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc "Opens the epmd port on `ip` (`opts[:port]`: another port, for tests)."
  @spec listen(:inet.ip_address(), keyword()) :: {:ok, :inet.socket()} | {:error, term()}
  def listen(ip, opts \\ []) do
    :gen_tcp.listen(Keyword.get(opts, :port, @port), [
      :binary,
      ip: ip,
      packet: 2,
      active: false,
      reuseaddr: true
    ])
  end

  @doc """
  Answers lookups for node `name` (the part before `@`) on distribution
  port `dist_port`, from the listening `socket` (which it takes over).
  """
  @spec start_link(:inet.socket(), String.t(), :inet.port_number()) :: {:ok, pid()}
  def start_link(socket, name, dist_port) do
    {:ok, epmd_port} = :inet.port(socket)
    pid = spawn_link(fn -> accept_loop(socket, name, dist_port, epmd_port) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    {:ok, pid}
  end

  @doc "Stops it and closes its port."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp accept_loop(socket, name, dist_port, epmd_port) do
    case :gen_tcp.accept(socket) do
      {:ok, conn} ->
        handler = spawn(fn -> serve(conn, name, dist_port, epmd_port) end)
        _ = :gen_tcp.controlling_process(conn, handler)
        send(handler, :go)
        accept_loop(socket, name, dist_port, epmd_port)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[cluster] epmd accept failed: #{inspect(reason)}")
        Process.sleep(100)
        accept_loop(socket, name, dist_port, epmd_port)
    end
  end

  defp serve(conn, name, dist_port, epmd_port) do
    receive do
      :go -> :ok
    after
      @recv_timeout -> :ok
    end

    with {:ok, request} <- :gen_tcp.recv(conn, 0, @recv_timeout),
         reply when is_binary(reply) <- reply(request, name, dist_port, epmd_port) do
      # Replies go out raw: epmd's answers have no length prefix.
      :ok = :inet.setopts(conn, packet: :raw)
      _ = :gen_tcp.send(conn, reply)
    end

    :gen_tcp.close(conn)
  end

  @doc false
  # The answer to one request, or nil (close without one).
  @spec reply(binary(), String.t(), :inet.port_number(), :inet.port_number()) :: binary() | nil
  def reply(<<@port_please2_req, name::binary>>, name, dist_port, _epmd_port) do
    <<@port2_resp, 0, dist_port::16, @node_type, @protocol, @dist_version::16, @dist_version::16,
      byte_size(name)::16, name::binary, 0::16>>
  end

  def reply(<<@port_please2_req, _other::binary>>, _name, _dist_port, _epmd_port),
    do: <<@port2_resp, 1>>

  def reply(<<@names_req>>, name, dist_port, epmd_port),
    do: <<epmd_port::32, "name #{name} at port #{dist_port}\n">>

  def reply(_request, _name, _dist_port, _epmd_port), do: nil
end
