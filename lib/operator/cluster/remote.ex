defmodule Operator.Cluster.Remote do
  @moduledoc """
  What this Operator does for the agents on the other members, through two
  `Operator.Cluster.Bus` services (only members reach the Bus):

    * `"operator.tool"`: runs one of this phone's agent tools
      (`{:tool, name, args}`) and answers with its result, so a member's
      agent can read this phone's location or sensors, post a notification
      here, read or write files here. Tools that would change this phone's
      Dyn layer or front, or that only make sense in one session, are not
      run for a peer (`remote?/1`), and neither is `cluster` itself, so one
      request can't fan out. Pictures a tool returns stay on this phone: a
      Bus reply is at most 64 KiB.
    * `"operator.message"`: shows a member's message (`{:message, text}`)
      in this phone's terminal, as a notice the agent here also reads on
      its next call, and as a notification.

  The agent's side is `Operator.Core.Tools.Cluster`.
  """
  use GenServer

  alias Operator.Cluster.Bus
  alias Operator.Core.Loop
  alias Operator.Core.Phone
  alias Operator.Core.Tool
  alias Operator.Core.ToolRegistry
  alias Operator.Core.ToolRunner

  require Logger

  @tool_service "operator.tool"
  @message_service "operator.message"
  # A Bus message is at most 64 KiB; leave room for the tuple around it.
  @max_reply 60_000
  @max_message 4_000
  @local_only ~w(cluster read_artifact dyn_write dyn_edit dyn_copy dyn_delete dyn_reset
                 dyn_propose front_open)

  @spec tool_service() :: String.t()
  def tool_service, do: @tool_service

  @spec message_service() :: String.t()
  def message_service, do: @message_service

  @spec max_message() :: pos_integer()
  def max_message, do: @max_message

  @doc "May a peer run tool `name` here?"
  @spec remote?(String.t()) :: boolean()
  def remote?(name), do: name not in @local_only

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Bus.register(@tool_service)
    :ok = Bus.register(@message_service)
    {:ok, %{}}
  end

  # Answered from a task each: a tool can take a while (a location fix, a
  # human on this phone picking a photo) and requests must not queue.
  @impl true
  def handle_info({:cluster_call, {pid, _ref} = from, request}, s) when is_pid(pid) do
    peer = node(pid)
    {:ok, _} = Task.start(fn -> _ = Bus.reply(from, answer(request, peer)) end)
    {:noreply, s}
  end

  def handle_info(_message, s), do: {:noreply, s}

  @doc false
  @spec answer(term(), node()) :: {:ok, String.t()} | {:error, String.t()}
  def answer({:tool, name, args}, peer) when is_binary(name) and is_map(args) do
    with true <- remote?(name) || {:error, "#{name} only runs for this phone's own agent"},
         {:ok, module} <- lookup(name) do
      Logger.info("[cluster] #{peer} runs #{name} here")
      run(module, args, peer)
    end
  end

  def answer({:message, text}, peer) when is_binary(text) and byte_size(text) <= @max_message do
    case String.trim(text) do
      "" ->
        {:error, "the message is empty"}

      text ->
        :ok = Loop.note(Operator.Core.current(), :aside, "#{peer} says: #{text}")
        _ = notify(peer, text)
        {:ok, "Shown in the terminal of #{Node.self()}."}
    end
  catch
    :exit, _ -> {:error, "the terminal on #{Node.self()} isn't running"}
  end

  def answer(_request, _peer), do: {:error, "not a request this Operator understands"}

  defp lookup(name) do
    case ToolRegistry.lookup(name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "no tool #{name} on #{Node.self()}"}
    end
  end

  defp run(module, args, peer) do
    ctx = %{
      session_id: "cluster",
      call_id: "cluster-#{System.unique_integer([:positive])}",
      data_dir: Operator.Paths.data_dir(),
      peer: peer
    }

    task = Task.async(fn -> args |> module.run(ctx) |> ToolRunner.to_result() end)

    case Task.yield(task, Tool.timeout_ms(module)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:images, images, text}}} ->
        {:ok, clip(text) <> "\n(#{length(images)} picture(s) stay on #{Node.self()}.)"}

      {:ok, {status, text}} ->
        {status, clip(text)}

      {:exit, reason} ->
        {:error, ToolRunner.crash_text(reason)}

      nil ->
        {:error, ToolRunner.timeout_text(module)}
    end
  end

  defp clip(text) when byte_size(text) <= @max_reply, do: text

  defp clip(text) do
    cut = binary_part(text, 0, @max_reply)
    # Not inside a UTF-8 character.
    cut = String.replace_invalid(cut, "")
    cut <> "\n… (cut at #{@max_reply} bytes)"
  end

  defp notify(peer, text) do
    Phone.request(
      :notify,
      %{title: "From #{peer}", body: String.slice(text, 0, 200), in_seconds: 0},
      5_000
    )
  end
end
