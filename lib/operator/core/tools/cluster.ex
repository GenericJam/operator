defmodule Operator.Core.Tools.Cluster do
  @moduledoc """
  Core tool: the other nodes in this phone's local cluster ([menu] ›
  cluster): list them, connect to any Erlang node by name and cookie (open
  mode), and, on the ones that are Operators, through
  `Operator.Cluster.Remote` there: run one of their agent tools, show
  them a message, or ask their agent something and get its answer
  (`Operator.Cluster.Ask`). A session that is answering another phone's
  question can't ask: an exchange is one question and one answer.
  """
  @behaviour Rho.Tool

  alias Operator.Cluster.Bus
  alias Operator.Cluster.Remote

  @impl true
  def name, do: "cluster"

  @impl true
  def description,
    do:
      "This phone's local cluster: other phones (Operators) and, in open mode, any Erlang " <>
        "node; each is a node like operator_9598e293b8@10.0.0.132. action `peers` lists them " <>
        "and whether each is connected. `connect` (open mode only: the user picks the mode " <>
        "in [menu] › cluster) connects to the node `peer` (its full name@host) with " <>
        "`cookie` (left out: this phone's) and keeps reconnecting it; then reach it with " <>
        "`eval` like any node: `:erpc.call(:\"name@host\", Mod, :fun, [args])`, " <>
        "`Node.spawn/2`, `:global`. On an Operator: `ask` gives `text` to that phone's agent " <>
        "and returns its answer (it may take a minute; a slower answer arrives later as a " <>
        "message): use it to have the other agent do or tell something. `tool` runs one of " <>
        "a peer's tools directly on that phone and returns the result: `tool` is its name " <>
        "(location, sensors, notify, clipboard, notes, http_get, camera_snap, photos_recent, " <>
        "file_list, file_read, file_write, ...), `args` its arguments; pictures stay on that " <>
        "phone. `message` only shows `text` in that phone's terminal and as a notification " <>
        "there; its agent doesn't answer. `peer` is a node name or a unique part of one, and " <>
        "may be left out when one peer is connected. While you are answering another " <>
        "phone's question you can't `ask`: put your answer in your reply. Pairing (paired " <>
        "mode) happens in the menu, not here."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["peers", "connect", "ask", "tool", "message"]
        },
        "peer" => %{"type" => "string"},
        "cookie" => %{"type" => "string"},
        "tool" => %{"type" => "string"},
        "args" => %{"type" => "object"},
        "text" => %{"type" => "string", "maxLength" => Remote.max_message()}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  # The peer's own tool timeout plus the trip.
  @impl true
  def timeout_ms, do: 150_000

  @impl true
  def run(args, ctx), do: run(args, ctx, &Bus.peers/0, &Bus.call/4)

  @doc false
  # `peers` and `call` stand in for the Bus in tests and the selftest;
  # `ctx[:connect]` for `Operator.Cluster.connect/2`.
  def run(%{"action" => "peers"}, _ctx, peers, _call) do
    case peers.() do
      [] ->
        {:ok,
         "No peers. The user pairs Operators, or turns on open mode for any Erlang node, " <>
           "in [menu] › cluster."}

      list ->
        lines =
          for %{node: node, connected: connected} <- list, do: "#{node}: #{state(connected)}"

        {:ok, Enum.join(["This phone: #{Node.self()}" | lines], "\n")}
    end
  end

  def run(%{"action" => "connect", "peer" => node} = args, ctx, _peers, _call)
      when is_binary(node) do
    connect = Map.get(ctx, :connect, &Operator.Cluster.connect/2)

    case connect.(node, args["cookie"]) do
      :ok -> {:ok, "Connected to #{node}. It stays in `peers` and reconnects until forgotten."}
      {:error, reason} -> {:error, "#{node}: #{Operator.Cluster.explain(reason)}"}
    end
  catch
    :exit, _ -> {:error, "the cluster isn't running"}
  end

  def run(%{"action" => "connect"}, _ctx, _peers, _call),
    do: {:error, "action connect needs `peer`: the node's full name, like app@10.0.0.5"}

  def run(%{"action" => "tool", "tool" => tool} = args, _ctx, peers, call)
      when is_binary(tool) and tool != "" do
    tool_args = Map.get(args, "args") || %{}

    with true <- is_map(tool_args) || {:error, "`args` must be an object"},
         {:ok, node} <- pick(args["peer"], peers.()) do
      request(call, node, Remote.tool_service(), {:tool, tool, tool_args}, timeout_ms() - 5_000)
    end
  end

  def run(%{"action" => "message", "text" => text} = args, _ctx, peers, call)
      when is_binary(text) and text != "" do
    with {:ok, node} <- pick(args["peer"], peers.()),
         do: request(call, node, Remote.message_service(), {:message, text}, 15_000)
  end

  def run(%{"action" => "ask", "text" => text} = args, ctx, peers, call)
      when is_binary(text) and text != "" do
    answering? = Map.get(ctx, :answering?, &Remote.answering?/1)

    if answering?.(ctx[:session_id]) do
      {:error,
       "You are answering another phone's question, so you can't ask one: put your answer " <>
         "in your reply, it goes back to that phone."}
    else
      with {:ok, node} <- pick(args["peer"], peers.()),
           do: request(call, node, Remote.ask_service(), {:ask, text}, timeout_ms() - 10_000)
    end
  end

  def run(%{"action" => "ask"}, _ctx, _peers, _call),
    do: {:error, "action ask needs a non-empty `text` (the question or request)"}

  def run(%{"action" => "tool"}, _ctx, _peers, _call),
    do: {:error, "action tool needs `tool` (the tool's name) and optionally `args`"}

  def run(%{"action" => "message"}, _ctx, _peers, _call),
    do: {:error, "action message needs a non-empty `text`"}

  def run(_args, _ctx, _peers, _call),
    do: {:error, "`action` is peers, connect, ask, tool or message"}

  defp state(true), do: "connected"
  defp state(false), do: "not connected"

  defp pick(nil, peers) do
    case Enum.filter(peers, & &1.connected) do
      [%{node: node}] -> {:ok, node}
      [] -> {:error, "no peer is connected#{listing(peers)}"}
      _ -> {:error, "more than one peer is connected: say which with `peer`#{listing(peers)}"}
    end
  end

  defp pick(name, peers) when is_binary(name) do
    case Enum.filter(peers, &String.contains?(Atom.to_string(&1.node), name)) do
      [%{node: node, connected: true}] -> {:ok, node}
      [%{node: node}] -> {:error, "#{node} isn't connected right now"}
      [] -> {:error, "no peer matches #{inspect(name)}#{listing(peers)}"}
      _ -> {:error, "#{inspect(name)} matches more than one peer#{listing(peers)}"}
    end
  end

  defp pick(_name, _peers), do: {:error, "`peer` must be a string"}

  defp listing([]), do: " (no peers)"
  defp listing(peers), do: ". Peers: " <> Enum.map_join(peers, ", ", &Atom.to_string(&1.node))

  defp request(call, node, service, request, timeout) do
    case call.(node, service, request, timeout) do
      {:ok, {:ok, text}} ->
        {:ok, "#{node}: #{text}"}

      {:ok, {:error, text}} ->
        {:error, "#{node}: #{text}"}

      {:error, :no_service} ->
        {:error,
         "#{node} doesn't answer Operator requests (not an Operator, or an older one): " <>
           "reach it with `eval`, e.g. `:erpc.call(:\"#{node}\", :erlang, :system_info, " <>
           "[:otp_release])`"}

      {:error, :timeout} ->
        {:error, "#{node} didn't answer within #{div(timeout, 1000)} s"}

      {:error, :down} ->
        {:error, "#{node} went away mid-request"}

      {:error, reason} ->
        {:error, "#{node}: #{inspect(reason)}"}
    end
  end

  @impl true
  def selftest do
    peer = :"operator_peer@10.0.0.2"
    peers = fn -> [%{node: peer, connected: true}] end

    call = fn ^peer, "operator.tool", {:tool, "location", %{}}, _timeout ->
      {:ok, {:ok, "51.05, -114.07"}}
    end

    case run(%{"action" => "tool", "tool" => "location"}, %{}, peers, call) do
      {:ok, "operator_peer@10.0.0.2: 51.05, -114.07"} -> :ok
      other -> {:error, "selftest: #{inspect(other)}"}
    end
  end
end
