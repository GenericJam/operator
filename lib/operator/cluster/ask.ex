defmodule Operator.Cluster.Ask do
  @moduledoc """
  One question from another phone's agent, answered by this phone's agent
  (`Operator.Cluster.Remote` runs it, the asker's side is the `cluster`
  tool's `ask`). The question goes into this phone's current session like a
  follow-up (`Operator.Core.Loop.ask/4`): a run starts if the agent is idle,
  otherwise it comes up when the current run would stop. The answer is the
  agent's last text after the question, sent back once that run ends.

  An exchange is one question and one answer. While a session is answering,
  its agent can't ask any phone (`Operator.Cluster.Remote.answering?/1`), so
  two agents can't keep waking each other. The asker waits `:reply_ms`
  (110 s); past that it hears "still working", and the answer, when it comes
  (up to `:late_ms`, 10 min), arrives there as a message.
  """

  alias Operator.Core.Loop
  alias Operator.Core.Session

  @reply_ms 110_000
  @late_ms 10 * 60_000

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Asks the agent of `loop` `text` on behalf of node `peer`. Options:
  `:reply` (`fn result -> _`, called exactly once, by `:reply_ms`), `:late`
  (`fn answer -> _`, an answer that missed the reply), `:on_session`
  (`fn session_id -> _`, before the question is queued), `:reply_ms`,
  `:late_ms`.
  """
  @spec run(pid(), String.t(), node(), keyword()) :: :ok
  def run(loop, text, peer, opts) do
    reply = Keyword.fetch!(opts, :reply)
    start = System.monotonic_time(:millisecond)
    id = "ask-#{System.unique_integer([:positive])}"

    case queue(loop, text, peer, id, opts) do
      {:ok, mon} ->
        reply_by = start + Keyword.get(opts, :reply_ms, @reply_ms)
        late_by = start + Keyword.get(opts, :late_ms, @late_ms)
        late = Keyword.get(opts, :late, fn _answer -> :ok end)
        first = await(loop, mon, id, reply_by)
        deliver(first, reply, fn -> await(loop, mon, id, late_by) end, late)

        Process.demonitor(mon, [:flush])
        _ = Loop.unsubscribe(loop)
        :ok

      :error ->
        reply.({:error, "the terminal on #{Node.self()} isn't running"})
        :ok
    end
  catch
    # The session went away mid-answer: the reply (or the late answer) is lost.
    :exit, _ -> :ok
  end

  # Past `:reply_ms` the asker hears "still working"; the answer, if it comes
  # by `:late_ms`, goes to `late`.
  defp deliver(:pending, reply, await_late, late) do
    reply.({:ok, "#{Node.self()} is still working on it; the answer will come as a message."})

    case await_late.() do
      {:ok, answer} -> late.(answer)
      _ -> :ok
    end
  end

  defp deliver(result, reply, _await_late, _late), do: reply.(result)

  defp queue(loop, text, peer, id, opts) do
    mon = Process.monitor(loop)
    :ok = Loop.subscribe(loop)
    Keyword.get(opts, :on_session, fn _ -> :ok end).(Loop.snapshot(loop).session_id)
    :ok = Loop.ask(loop, "#{peer} asks: #{text}", id, peer)
    # A run that ended before the question was queued isn't the one taking
    # it; the loop sent its agent_end before answering the call above.
    flush_ends()
    {:ok, mon}
  catch
    :exit, _ -> :error
  end

  defp flush_ends do
    receive do
      {:operator_core, _sid, %{type: :agent_end}} -> flush_ends()
    after
      0 -> :ok
    end
  end

  # The first agent_end after the question was queued ends the run that
  # takes it: a queued follow-up is drained before a run finishes.
  defp await(loop, mon, id, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:operator_core, _sid, %{type: :agent_end, reason: reason}} ->
        case answer(Loop.snapshot(loop).entries, id) do
          {:ok, text} -> {:ok, text}
          :no_text -> {:error, "#{Node.self()}'s agent stopped without an answer (#{reason})"}
          :absent -> {:error, "#{Node.self()}'s agent was stopped before your question came up"}
        end

      {:DOWN, ^mon, :process, _, _} ->
        {:error, "#{Node.self()}'s session closed before it answered"}
    after
      left -> :pending
    end
  end

  @doc """
  The answer to question `id` in `entries`: the last assistant text after
  it, before the next user message. `:no_text` when it was taken but not
  answered, `:absent` when it isn't there (dropped by a stop).
  """
  @spec answer([map()], String.t()) :: {:ok, String.t()} | :no_text | :absent
  def answer(entries, id) do
    case Enum.drop_while(entries, &(get_in(&1, ["message", "ask"]) != id)) do
      [] ->
        :absent

      [_question | after_it] ->
        after_it
        |> Enum.take_while(&(get_in(&1, ["message", "role"]) != "user"))
        |> Enum.filter(&(get_in(&1, ["message", "role"]) == "assistant"))
        |> Enum.map(&Session.text(&1["message"]["content"]))
        |> Enum.reject(&(String.trim(&1) == ""))
        |> List.last()
        |> case do
          nil -> :no_text
          text -> {:ok, text}
        end
    end
  end
end
