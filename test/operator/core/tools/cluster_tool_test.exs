defmodule Operator.Core.Tools.ClusterTest do
  use ExUnit.Case, async: true

  alias Operator.Cluster.Remote
  alias Operator.Core.Tools.Cluster, as: Tool

  @a :"operator_aaaa111111@10.0.0.2"
  @b :"operator_bbbb222222@10.0.0.3"

  defp peers(list), do: fn -> list end

  # A Bus stand-in that records the request and gives `answer`.
  defp bus(answer) do
    test = self()

    fn node, service, request, _timeout ->
      send(test, {:called, node, service, request})
      answer
    end
  end

  test "passes its own selftest" do
    assert Tool.selftest() == :ok
  end

  test "lists this phone and each peer with whether it is connected" do
    list = [%{node: @a, connected: true}, %{node: @b, connected: false}]
    assert {:ok, text} = Tool.run(%{"action" => "peers"}, %{}, peers(list), bus(nil))
    assert text =~ "operator_aaaa111111@10.0.0.2: connected"
    assert text =~ "operator_bbbb222222@10.0.0.3: not connected"

    assert {:ok, "No paired peers" <> _} =
             Tool.run(%{"action" => "peers"}, %{}, peers([]), bus(nil))
  end

  test "runs a tool on the one connected peer and returns that phone's answer" do
    list = [%{node: @a, connected: true}, %{node: @b, connected: false}]
    call = bus({:ok, {:ok, "51.05, -114.07"}})
    args = %{"action" => "tool", "tool" => "location", "args" => %{"accuracy" => "high"}}

    assert {:ok, "operator_aaaa111111@10.0.0.2: 51.05, -114.07"} =
             Tool.run(args, %{}, peers(list), call)

    assert_received {:called, @a, "operator.tool", {:tool, "location", %{"accuracy" => "high"}}}
  end

  test "a peer's tool error comes back as this call's error" do
    call = bus({:ok, {:error, "no location permission"}})

    assert {:error, "operator_aaaa111111@10.0.0.2: no location permission"} =
             Tool.run(
               %{"action" => "tool", "tool" => "location"},
               %{},
               peers([%{node: @a, connected: true}]),
               call
             )
  end

  test "peer names a node by any unique part; ambiguity, absence and disconnection are errors" do
    both = [%{node: @a, connected: true}, %{node: @b, connected: true}]
    msg = %{"action" => "message", "text" => "hi"}

    assert {:error, "more than one peer is connected" <> _} =
             Tool.run(msg, %{}, peers(both), bus(nil))

    assert {:ok, _} =
             Tool.run(Map.put(msg, "peer", "bbbb"), %{}, peers(both), bus({:ok, {:ok, "shown"}}))

    assert_received {:called, @b, "operator.message", {:message, "hi"}}

    assert {:error, "no peer matches" <> _} =
             Tool.run(Map.put(msg, "peer", "zzzz"), %{}, peers(both), bus(nil))

    assert {:error, "\"operator_\" matches more than one peer" <> _} =
             Tool.run(Map.put(msg, "peer", "operator_"), %{}, peers(both), bus(nil))

    assert {:error, "operator_bbbb222222@10.0.0.3 isn't connected" <> _} =
             Tool.run(
               Map.put(msg, "peer", "bbbb"),
               %{},
               peers([%{node: @b, connected: false}]),
               bus(nil)
             )

    refute_received {:called, _, _, _}
  end

  test "a peer that is gone or silent is a readable error" do
    one = peers([%{node: @a, connected: true}])
    msg = %{"action" => "message", "text" => "hi"}

    assert {:error, text} = Tool.run(msg, %{}, one, bus({:error, :timeout}))
    assert text =~ "didn't answer"

    assert {:error, text} = Tool.run(msg, %{}, one, bus({:error, :no_service}))
    assert text =~ "doesn't answer cluster requests"
  end

  describe "the peer's side" do
    test "tools that change the phone's own app or session are not run for a peer" do
      for name <- ~w(cluster dyn_write dyn_propose front_open read_artifact) do
        assert {:error, text} = Remote.answer({:tool, name, %{}}, @a)
        assert text =~ "only runs for this phone's own agent"
      end
    end

    test "garbage requests and oversized messages are refused" do
      assert {:error, _} = Remote.answer(:hello, @a)
      assert {:error, _} = Remote.answer({:tool, "notes", "not a map"}, @a)

      assert {:error, _} =
               Remote.answer({:message, String.duplicate("x", Remote.max_message() + 1)}, @a)
    end
  end
end
