defmodule Operator.Cluster.MdnsTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp(:dns_rec, Record.extract(:dns_rec, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecordp(:dns_header, Record.extract(:dns_header, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecordp(:dns_rr, Record.extract(:dns_rr, from_lib: "kernel/src/inet_dns.hrl"))

  # A responder on loopback standing in for the mDNS group: it answers the
  # one query it gets with `records`, from its own (unicast) address, under
  # the query's ID (or `opts[:id]`).
  defp responder(records, opts \\ []) do
    {:ok, socket} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, {from, from_port, query}} = :gen_udp.recv(socket, 0, 5_000)
        send(test, {:query, query})
        <<id::16, _::binary>> = query

        reply =
          dns_rec(
            header: dns_header(id: Keyword.get(opts, :id, id), qr: true, aa: true),
            anlist: for({name, ip} <- records, do: dns_rr(domain: name, type: :a, data: ip))
          )

        :ok = :gen_udp.send(socket, from, from_port, :inet_dns.encode(reply))
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(pid, :stop) end)
    {{127, 0, 0, 1}, port}
  end

  test "asks for a unicast answer and takes the address of the name asked, in any case" do
    dest = responder([{~c"other.local", {10, 0, 0, 9}}, {~c"Nerves-7EF3.local", {10, 0, 0, 31}}])

    assert {:ok, {10, 0, 0, 31}} = :operator_mdns.getaddr(~c"nerves-7ef3.local.", 2_000, dest)

    assert_received {:query, query}
    # One question: nerves-7ef3.local, type A, class IN with the unicast-response bit.
    assert <<_id::16, 0::16, 1::16, 0::48, 11, "nerves-7ef3", 5, "local", 0, 1::16, 0x8001::16>> =
             query
  end

  test "an answer to some other query is not taken" do
    dest = responder([{~c"nerves-7ef3.local", {10, 0, 0, 66}}], id: 0)
    assert {:error, :nxdomain} = :operator_mdns.getaddr(~c"nerves-7ef3.local", 300, dest)
  end

  test "no answer for the name is nxdomain once the time is up" do
    dest = responder([{~c"other.local", {10, 0, 0, 9}}])
    assert {:error, :nxdomain} = :operator_mdns.getaddr(~c"nerves-7ef3.local", 300, dest)
  end

  test "only .local names go to mDNS" do
    assert :operator_mdns.local(~c"nerves-7ef3.local")
    assert :operator_mdns.local(~c"Mac.LOCAL.")
    refute :operator_mdns.local(~c"10.0.0.31")
    refute :operator_mdns.local(~c"example.com")
    refute :operator_mdns.local({10, 0, 0, 31})
  end
end
