defmodule Operator.Cluster.Remote do
  @moduledoc """
  What this Operator does for the agents on the other members, through
  three `Operator.Cluster.Bus` services (only members reach the Bus):

    * `"operator.tool"`: runs one of this phone's agent tools
      (`{:tool, name, args}`) and answers with its result, so a member's
      agent can read this phone's location or sensors, post a notification
      here, read or write files here. Only the Core tools on an allowlist
      are run for a peer (`remote?/1`): the phone's senses, notifications,
      notes and friction, files, `http_get`, the docs, and looking at (not
      changing) the Dyn layer and the front. Everything else only runs for
      this phone's own agent: tools that change the Dyn layer or drive the
      front, that only make sense in one session (`read_artifact`, `todo`,
      `task`), that reach into the app itself (`eval`, `logs`) or rewrite
      the agent's own instructions (`instructions`, `skill`), `cluster`
      (so one request can't fan out), and any Core tool added later until
      it is put on the list. The current Dyn generation's own tools are run
      for peers, as they always were: the agent built them, and Dyn code is
      held to the Dyn sandbox. Pictures a tool returns stay on this phone:
      a Bus reply is at most 64 KiB.
    * `"operator.message"`: shows a member's message (`{:message, text}`)
      in this phone's terminal, as a notice the agent here also reads on
      its next call, and as a notification. It doesn't start a run.
    * `"operator.ask"`: a member's agent asks this one (`{:ask, text}`):
      this phone's agent takes it as its next message and its answer goes
      back (`Operator.Cluster.Ask`). One question per peer at a time, #{3}
      in all; while answering, this agent can't ask anyone, so an exchange
      ends with the answer.

  The agent's side is `Operator.Core.Tools.Cluster`.
  """
  use GenServer

  alias Operator.Cluster.Ask
  alias Operator.Cluster.Bus
  alias Operator.Core.Dyn
  alias Operator.Core.Loop
  alias Operator.Core.Phone
  alias Operator.Core.Tool
  alias Operator.Core.ToolRegistry
  alias Operator.Core.ToolRunner

  require Logger

  @tool_service "operator.tool"
  @message_service "operator.message"
  @ask_service "operator.ask"
  # Questions answered at once, from all peers together (one per peer).
  @max_asks 3
  # A Bus message is at most 64 KiB; leave room for the tuple around it.
  @max_reply 60_000
  @max_message 4_000
  # The Core tools a peer may run; anything else Core is this agent's only.
  @peer_tools ~w(notes friction http_get clipboard location notify camera_photo camera_snap
                 pick_photos photos_recent sensors file_list file_read file_write file_copy
                 file_delete file_pick dyn_files dyn_read dyn_status front_screens
                 front_screenshot read_guide read_doc)

  @spec tool_service() :: String.t()
  def tool_service, do: @tool_service

  @spec message_service() :: String.t()
  def message_service, do: @message_service

  @spec ask_service() :: String.t()
  def ask_service, do: @ask_service

  @doc """
  Is session `session_id` answering another phone's question right now?
  Its agent may not ask a phone anything meanwhile: an exchange is one
  question and one answer.
  """
  @spec answering?(String.t()) :: boolean()
  def answering?(session_id) do
    GenServer.call(__MODULE__, {:answering?, session_id})
  catch
    :exit, _ -> false
  end

  @spec max_message() :: pos_integer()
  def max_message, do: @max_message

  @doc """
  May a peer run tool `name` here? A Core tool on the allowlist, or one
  of the current Dyn generation's (a Core tool's name always wins).
  """
  @spec remote?(String.t()) :: boolean()
  def remote?(name), do: name in @peer_tools or dyn_tool?(name)

  defp dyn_tool?(name) do
    case Dyn.lookup({:tool, name}) do
      {:ok, module} -> ToolRegistry.lookup(name) == {:ok, module}
      :error -> false
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Bus.register(@tool_service)
    :ok = Bus.register(@message_service)
    :ok = Bus.register(@ask_service)
    {:ok, %{asks: %{}}}
  end

  @impl true
  def handle_call({:answering?, session_id}, _from, s),
    do: {:reply, Enum.any?(s.asks, fn {_peer, a} -> a.session == session_id end), s}

  @impl true
  def handle_cast({:answering, peer, session_id}, s) do
    asks = if s.asks[peer], do: put_in(s.asks[peer].session, session_id), else: s.asks
    {:noreply, %{s | asks: asks}}
  end

  # A question takes this phone's agent for a whole run: one at a time per
  # peer, a few in all.
  @impl true
  def handle_info({:cluster_call, {pid, _ref} = from, {:ask, text}}, s) when is_pid(pid) do
    peer = node(pid)

    cond do
      not (is_binary(text) and String.trim(text) != "" and byte_size(text) <= @max_message) ->
        _ = Bus.reply(from, {:error, "a question is 1..#{@max_message} bytes of text"})
        {:noreply, s}

      Map.has_key?(s.asks, peer) ->
        _ = Bus.reply(from, {:error, "#{Node.self()} is still answering your last question"})
        {:noreply, s}

      map_size(s.asks) >= @max_asks ->
        _ = Bus.reply(from, {:error, "#{Node.self()} is busy answering other phones"})
        {:noreply, s}

      true ->
        {_pid, mon} = spawn_monitor(fn -> answer_ask(from, text, peer) end)
        {:noreply, put_in(s.asks[peer], %{mon: mon, session: nil})}
    end
  end

  # Answered from a task each: a tool can take a while (a location fix, a
  # human on this phone picking a photo) and requests must not queue.
  def handle_info({:cluster_call, {pid, _ref} = from, request}, s) when is_pid(pid) do
    peer = node(pid)
    {:ok, _} = Task.start(fn -> _ = Bus.reply(from, answer(request, peer)) end)
    {:noreply, s}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, s) do
    {:noreply, %{s | asks: Map.reject(s.asks, fn {_peer, a} -> a.mon == mon end)}}
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp answer_ask(from, text, peer) do
    Logger.info("[cluster] #{peer} asks this phone's agent")

    Ask.run(Operator.Core.current(), String.trim(text), peer,
      reply: fn {status, answer} -> Bus.reply(from, {status, clip(answer)}) end,
      late: fn answer ->
        Bus.call(peer, @message_service, {:message, "Answer to your question: " <> clip(answer)})
      end,
      on_session: &GenServer.cast(__MODULE__, {:answering, peer, &1})
    )
  end

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
