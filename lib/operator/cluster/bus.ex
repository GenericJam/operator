defmodule Operator.Cluster.Bus do
  @moduledoc """
  What code running on the cluster may use, front (Dyn) screens and the
  agent's `cluster` tool included: who the peers are, topics to publish and
  subscribe to, and named services to call on a peer. Everything goes
  through the `:pg` scope `Operator.Cluster` runs, so it only ever reaches
  processes that joined it here; there is no way through this module to
  `:rpc`, to another node's system processes, or to change the cluster
  (pairing, forgetting: `Operator.Cluster`, from the menu).

  Topics and services are strings up to #{100} bytes. Messages are plain
  data: no functions anywhere in them (a peer never runs code it was
  sent), at most #{64} KiB in the external term format.

      # a chat: every phone's screen subscribes, any phone publishes
      :ok = Operator.Cluster.Bus.subscribe("chat")
      :ok = Operator.Cluster.Bus.publish("chat", %{from: "kevin", text: "hi"})
      # handle_info({:cluster, "chat", from_node, %{text: text}}, socket)

      # a service: one process answers calls from the other phones
      :ok = Operator.Cluster.Bus.register("counter")
      # handle_info({:cluster_call, from, :get}, s) -> Bus.reply(from, s.count)
      {:ok, n} = Operator.Cluster.Bus.call(peer_node, "counter", :get)

  Without the cluster running, topics and services still work on this
  phone alone, and `peers/0` is `[]`.
  """

  @max_name 100
  @max_message 64 * 1024

  @typedoc "A topic or service name."
  @type name :: String.t()

  @doc """
  The paired peers that aren't revoked: `%{node: node, connected: boolean}`.
  `this_node/0` is this phone's node.
  """
  @spec peers() :: [%{node: node(), connected: boolean()}]
  def peers do
    status = Operator.Cluster.status()

    for %{revoked: false, node: node, connected: connected} <- status.peers,
        do: %{node: String.to_atom(node), connected: connected}
  catch
    :exit, _ -> []
  end

  @doc "This node's name (`:nonode@nohost` while the cluster is off)."
  @spec this_node() :: node()
  def this_node, do: Node.self()

  @doc "Receive `{:cluster, topic, from_node, message}` for every publish on `topic`."
  @spec subscribe(name()) :: :ok | {:error, term()}
  def subscribe(topic) do
    with :ok <- check_name(topic), do: :pg.join(scope(), {:topic, topic}, self())
  end

  @doc "Stop receiving `topic`."
  @spec unsubscribe(name()) :: :ok | {:error, term()}
  def unsubscribe(topic) do
    with :ok <- check_name(topic) do
      _ = :pg.leave(scope(), {:topic, topic}, self())
      :ok
    end
  end

  @doc "Sends `message` to every subscriber of `topic`, on every node (this one too)."
  @spec publish(name(), term()) :: :ok | {:error, term()}
  def publish(topic, message) do
    with :ok <- check_name(topic),
         :ok <- check_message(message) do
      for pid <- :pg.get_members(scope(), {:topic, topic}),
          do: send(pid, {:cluster, topic, Node.self(), message})

      :ok
    end
  end

  @doc """
  Offers the calling process as `service` on this node: it gets
  `{:cluster_call, from, request}` and answers with `reply/2`.
  """
  @spec register(name()) :: :ok | {:error, term()}
  def register(service) do
    with :ok <- check_name(service), do: :pg.join(scope(), {:service, service}, self())
  end

  @doc """
  Calls `service` on `node` (this node too) and waits up to `timeout` ms:
  `{:ok, reply}`, or `{:error, :no_service | :timeout | :down | reason}`.
  """
  @spec call(node(), name(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(node, service, request, timeout \\ 5_000) when is_atom(node) do
    with :ok <- check_name(service),
         :ok <- check_message(request),
         [pid | _] <- members_on(node, service) do
      ref = Process.monitor(pid)
      send(pid, {:cluster_call, {self(), ref}, request})

      receive do
        {^ref, reply} ->
          Process.demonitor(ref, [:flush])
          {:ok, reply}

        {:DOWN, ^ref, :process, _, _} ->
          {:error, :down}
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          {:error, :timeout}
      end
    else
      [] -> {:error, :no_service}
      {:error, _} = error -> error
    end
  end

  @doc "Answers a `{:cluster_call, from, request}`."
  @spec reply({pid(), reference()}, term()) :: :ok | {:error, term()}
  def reply({pid, ref}, reply) when is_pid(pid) and is_reference(ref) do
    with :ok <- check_message(reply) do
      send(pid, {ref, reply})
      :ok
    end
  end

  defp members_on(node, service),
    do: Enum.filter(:pg.get_members(scope(), {:service, service}), &(node(&1) == node))

  defp scope, do: Operator.Cluster.pg_scope()

  defp check_name(name) when is_binary(name) and byte_size(name) in 1..@max_name, do: :ok
  defp check_name(_name), do: {:error, :bad_name}

  defp check_message(message) do
    cond do
      has_fun?(message) -> {:error, :function_in_message}
      :erlang.external_size(message) > @max_message -> {:error, :too_large}
      true -> :ok
    end
  end

  defp has_fun?(term) when is_function(term), do: true
  defp has_fun?(term) when is_list(term), do: list_has_fun?(term)
  defp has_fun?(term) when is_tuple(term), do: term |> Tuple.to_list() |> list_has_fun?()

  defp has_fun?(term) when is_map(term),
    do: term |> Map.to_list() |> list_has_fun?()

  defp has_fun?(_term), do: false

  # Improper lists too.
  defp list_has_fun?([head | tail]), do: has_fun?(head) or list_has_fun?(tail)
  defp list_has_fun?([]), do: false
  defp list_has_fun?(tail), do: has_fun?(tail)
end
