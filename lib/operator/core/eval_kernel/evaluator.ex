defmodule Operator.Core.EvalKernel.Evaluator do
  @moduledoc """
  The process a session's evaluations run in, one after the other, so it
  lives on between calls like an iex shell. Plugins answer the process
  that called them (a NIF's `enif_send` to the caller: screencast frames,
  vision results, camera results), often after the call that started
  them; in a process per call those answers would be lost.

  Between calls it takes every message that arrives into a buffer of the
  newest 200 (counting the ones it drops), so a stream left running
  can't grow the mailbox without bound. While a call runs it leaves the
  mailbox alone: a `receive` in the evaluated code finds what arrives
  during the call. `inbox/1` (the evaluated code's `inbox.()`) hands
  over the buffer and whatever is waiting in the mailbox.

  `Operator.Core.EvalKernel` sends the requests (a function to run with
  its output captured and a heap cap), kills the process at a timeout or
  a stop, and starts another when it has died. It exits when its owner
  (the kernel's store) goes.
  """

  @request :"$operator_eval"
  @inbox {__MODULE__, :inbox}
  @dropped {__MODULE__, :dropped}
  @owner {__MODULE__, :owner}
  @orphan {__MODULE__, :orphan}
  @max_inbox 200

  defguardp request?(msg)
            when is_tuple(msg) and tuple_size(msg) == 4 and elem(msg, 0) == @request

  @doc "Starts an evaluator that exits when `owner` (nil: none) does."
  @spec start(pid() | nil, pos_integer()) :: pid()
  def start(owner, max_heap_bytes), do: spawn(fn -> init(owner, max_heap_bytes) end)

  @doc """
  Asks `pid` to run `fun` with `capture` as its group leader and a heap cap
  of `max_heap_bytes` (binaries included); it answers `{ref, fun.()}`.
  """
  @spec request(pid(), reference(), pid(), pos_integer(), (-> term())) :: :ok
  def request(pid, ref, capture, max_heap_bytes, fun) do
    send(pid, {@request, self(), ref, {capture, max_heap_bytes, fun}})
    :ok
  end

  @doc """
  The messages this process has received and not taken yet, oldest first,
  and forgets them. With `timeout_ms` and nothing there yet, waits that
  long for one.
  """
  @spec inbox(non_neg_integer()) :: [term()]
  def inbox(timeout_ms \\ 0) when is_integer(timeout_ms) and timeout_ms >= 0 do
    drain()

    case take() do
      [] when timeout_ms > 0 ->
        receive do
          msg when not request?(msg) ->
            buffer(msg)
            drain()
            take()
        after
          timeout_ms -> []
        end

      msgs ->
        msgs
    end
  end

  @doc """
  How many messages the buffer dropped since the last call to this, for
  the result's notes; nil when none.
  """
  @spec take_dropped() :: pos_integer() | nil
  def take_dropped do
    case Process.put(@dropped, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp init(owner, max_heap_bytes) do
    if owner, do: Process.put(@owner, Process.monitor(owner))
    Process.put(@inbox, {:queue.new(), 0})
    Process.put(@dropped, 0)
    heap(max_heap_bytes)
    loop()
  end

  defp loop do
    receive do
      {@request, from, ref, {capture, max_heap_bytes, fun}} ->
        serve(from, ref, capture, max_heap_bytes, fun)

      msg ->
        buffer(msg)
    end

    if Process.get(@orphan), do: exit(:normal), else: loop()
  end

  defp serve(from, ref, capture, max_heap_bytes, fun) do
    heap(max_heap_bytes)
    leader = Process.group_leader()
    Process.group_leader(self(), capture)
    result = fun.()
    Process.group_leader(self(), leader)
    send(from, {ref, result})
    # What the call left on the heap goes now, not at some later call.
    :erlang.garbage_collect()
  end

  defp heap(bytes) do
    Process.flag(:max_heap_size, %{
      size: div(bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })
  end

  defp drain do
    receive do
      msg when not request?(msg) ->
        buffer(msg)
        drain()
    after
      0 -> :ok
    end
  end

  defp buffer({:DOWN, ref, :process, _, _} = msg) do
    if ref == Process.get(@owner),
      do: Process.put(@orphan, true),
      else: keep(msg)
  end

  defp buffer(msg), do: keep(msg)

  defp keep(msg) do
    {q, n} = Process.get(@inbox, {:queue.new(), 0})
    q = :queue.in(msg, q)

    if n >= @max_inbox do
      Process.put(@inbox, {:queue.drop(q), n})
      Process.put(@dropped, Process.get(@dropped, 0) + 1)
    else
      Process.put(@inbox, {q, n + 1})
    end
  end

  defp take do
    {q, _} = Process.put(@inbox, {:queue.new(), 0}) || {:queue.new(), 0}
    :queue.to_list(q)
  end
end
