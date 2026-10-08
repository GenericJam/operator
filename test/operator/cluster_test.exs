defmodule Operator.ClusterTest do
  use Mob.ScreenCase, async: false

  alias Operator.Cluster
  alias Operator.Cluster.Bus
  alias Operator.Cluster.Identity
  alias Operator.Cluster.Invite
  alias Operator.Cluster.Tls
  alias Operator.Links

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({Cluster, dir: Path.join(dir, "cluster"), boot_dist: false})
    :ok
  end

  @invite %{
    node: "operator_0123456789@192.168.1.20",
    fingerprint: String.duplicate("ab", 32),
    cookie: "0123456789abcdef0123456789abcdef",
    secret: "pairing-window-secret-0123456789",
    port: 9370
  }

  describe "pairing invites" do
    test "round trip through the app link router does not intern the node name" do
      invite = %{@invite | node: "operator_#{System.unique_integer([:positive])}@192.168.1.20"}
      refute atom_exists?(invite.node)
      link = Invite.link(invite)
      assert {:ok, ^invite} = Invite.parse(link)
      assert {:cluster, ^invite} = Links.handle(link)
      refute atom_exists?(invite.node)
    end

    test "rejects malformed, incomplete, foreign, and newer codes" do
      assert :not_cluster = Invite.parse("https://example.com")
      assert {:error, "That cluster code is incomplete."} = Invite.parse("operator://cluster?v=1")

      assert {:error, "That cluster code is from a newer Operator" <> _} =
               Invite.parse("operator://cluster?v=2")

      bad = Invite.link(%{@invite | fingerprint: "not-a-fingerprint"})
      assert {:error, "That cluster code has a bad fingerprint."} = Invite.parse(bad)

      no_secret = String.replace(Invite.link(@invite), ~r/&secret=[^&]+/, "")
      assert {:error, "That cluster code is incomplete."} = Invite.parse(no_secret)
    end
  end

  describe "identity and TLS pins" do
    test "a generated identity survives PEM and its self-signed certificate verifies" do
      identity = Identity.generate("operator_test")
      assert Identity.name(identity) == "operator_test"
      assert byte_size(identity.fingerprint) == 64
      assert {:ok, restored} = identity |> Identity.to_pem() |> Identity.from_pem()
      assert restored.cert == identity.cert
      assert restored.fingerprint == identity.fingerprint
      assert :public_key.pkix_is_self_signed(identity.cert)
    end

    test "clients require a pin; a server pairing window records one pending fingerprint" do
      identity = Identity.generate("operator_peer")
      cert = :public_key.pkix_decode_cert(identity.cert, :otp)

      Tls.put_pins([], [])
      assert {:fail, {:not_pinned, _}} = Tls.verify(cert, :valid, :client)

      Tls.put_pins([identity.fingerprint], [])
      assert {:valid, :client} = Tls.verify(cert, :valid, :client)

      Tls.put_pins([], [])
      :ok = Tls.open_window(System.monotonic_time(:millisecond) + 1_000)
      assert {:valid, :server} = Tls.verify(cert, :valid, :server)
      assert Tls.take_pending(identity.fingerprint)
      refute Tls.take_pending(identity.fingerprint)
    end

    test "a pending certificate without the pairing window's secret is not pinned" do
      identity = Identity.generate("operator_late")
      cert = :public_key.pkix_decode_cert(identity.cert, :otp)
      :ok = Tls.open_window(System.monotonic_time(:millisecond) + 1_000)
      assert {:valid, :server} = Tls.verify(cert, :valid, :server)

      # The cookie got it through distribution; it has no (or a stale) secret.
      for secret <- [nil, "pairing-window-secret-0123456789"] do
        GenServer.cast(
          Cluster,
          {:hello, :"operator_late@127.0.0.1", identity.fingerprint, [], secret}
        )
      end

      assert Cluster.status().peers == []
    end

    test "does not move an established member to another cookie or restore a revoked peer" do
      assert {:error, :restart_needed} = Cluster.join(@invite)
      assert [%{fingerprint: fingerprint, revoked: false}] = Cluster.status().peers

      other = %{
        @invite
        | node: "operator_other@192.168.1.21",
          fingerprint: String.duplicate("cd", 32),
          cookie: "fedcba9876543210fedcba9876543210"
      }

      assert {:error, :different_cluster} = Cluster.join(other)
      assert [peer] = Cluster.status().peers
      assert peer.fingerprint == fingerprint

      assert :ok = Cluster.forget(fingerprint)
      # The forgotten peer's copy of the cookie no longer opens distribution.
      assert {:ok, cookie} = Operator.SecureStore.get("cluster_cookie")
      assert cookie != @invite.cookie
      assert {:error, :revoked} = Cluster.join(@invite)
    end

    test "a member that missed a cookie change takes it from a member it knows" do
      assert {:error, :restart_needed} = Cluster.join(@invite)
      newer = %{@invite | cookie: "abcdefabcdefabcdefabcdefabcdefab"}
      assert {:error, :restart_needed} = Cluster.join(newer)
      assert Operator.SecureStore.get("cluster_cookie") == {:ok, newer.cookie}
    end
  end

  describe "bounded cluster bus" do
    test "publishes locally and calls only a registered service" do
      topic = "test-#{System.unique_integer([:positive])}"
      service = "echo-#{System.unique_integer([:positive])}"
      :ok = Bus.subscribe(topic)
      :ok = Bus.publish(topic, %{text: "hello"})
      assert_receive {:cluster, ^topic, from, %{text: "hello"}}
      assert from == Node.self()

      parent = self()

      server =
        spawn(fn ->
          :ok = Bus.register(service)
          send(parent, :service_ready)
          service_loop()
        end)

      assert_receive :service_ready
      assert {:ok, {:echo, 42}} = Bus.call(Node.self(), service, 42)
      Process.exit(server, :kill)
      assert {:error, :no_service} = Bus.call(Node.self(), "missing", :request, 10)
    end

    test "rejects executable and oversized messages" do
      assert {:error, :function_in_message} = Bus.publish("topic", fn -> :no end)
      assert {:error, :too_large} = Bus.publish("topic", :binary.copy(<<0>>, 70_000))
      assert {:error, :bad_name} = Bus.publish("", :message)
      assert {:error, :bad_name} = Bus.publish(String.duplicate("x", 101), :message)
    end
  end

  describe "cluster screen" do
    test "reviews a parsed peer without joining it" do
      view = mount_screen(Operator.ClusterScreen, %{invite: @invite})
      assert_renderable(view)
      shown = text(view)
      assert shown =~ "local TLS cluster"
      assert shown =~ "join this peer?"
      assert shown =~ @invite.node
      assert shown =~ String.slice(@invite.fingerprint, 0, 16)
      assert view |> render_info({:tap, :back}) |> navigated_to() == {:pop}
    end
  end

  defp atom_exists?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp service_loop do
    receive do
      {:cluster_call, from, request} ->
        :ok = Bus.reply(from, {:echo, request})
        service_loop()
    end
  end
end
