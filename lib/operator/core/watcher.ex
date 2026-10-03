defmodule Operator.Core.Watcher do
  @moduledoc """
  The part of a background observer (`Operator.Core.KeepAlive`,
  `Operator.Core.Voice`) that follows `Operator.Core.Current`'s loops: it
  `watch/1`es Current (again after Current restarts), monitors every loop
  Current announces, and turns the bookkeeping messages into
  `{:loop_up, session_id, watcher}` / `{:loop_down, session_id, watcher}`.
  The observer gets the loops' events itself, as
  `{:operator_core, session_id, event}`.
  """

  alias Operator.Core.Current

  @retry_ms 500

  @type t :: %{
          current: GenServer.server(),
          current_ref: reference() | nil,
          loops: %{pid() => {reference(), String.t()}}
        }

  @spec new(GenServer.server()) :: t()
  def new(current), do: %{current: current, current_ref: nil, loops: %{}}

  @doc "Watches Current, or retries in a moment (as `:watch_current`) while it is down."
  @spec watch(t()) :: t()
  def watch(w) do
    with pid when is_pid(pid) <- GenServer.whereis(w.current),
         ref = Process.monitor(pid),
         :ok <- call_watch(pid, ref) do
      %{w | current_ref: ref}
    else
      _ ->
        Process.send_after(self(), :watch_current, @retry_ms)
        %{w | current_ref: nil}
    end
  end

  @doc "Handles a watcher message; `:ignore` for anything else."
  @spec handle(term(), t()) ::
          {:loop_up | :loop_down, String.t(), t()} | {:ok, t()} | :ignore
  def handle({:operator_core_loop, pid, session_id}, w) do
    if Map.has_key?(w.loops, pid) do
      {:ok, w}
    else
      loops = Map.put(w.loops, pid, {Process.monitor(pid), session_id})
      {:loop_up, session_id, %{w | loops: loops}}
    end
  end

  def handle(:watch_current, w), do: {:ok, watch(w)}

  def handle({:DOWN, ref, :process, _pid, _reason}, %{current_ref: ref} = w),
    do: {:ok, watch(%{w | current_ref: nil})}

  def handle({:DOWN, ref, :process, pid, _reason}, w) do
    case w.loops do
      %{^pid => {^ref, session_id}} ->
        {:loop_down, session_id, %{w | loops: Map.delete(w.loops, pid)}}

      _ ->
        :ignore
    end
  end

  def handle(_message, _w), do: :ignore

  @doc "Whether a live loop of `session_id` is still watched."
  @spec session?(t(), String.t()) :: boolean()
  def session?(w, session_id),
    do: Enum.any?(w.loops, fn {_pid, {_, sid}} -> sid == session_id end)

  defp call_watch(pid, ref) do
    Current.watch(pid)
  catch
    :exit, _ ->
      Process.demonitor(ref, [:flush])
      :error
  end
end
