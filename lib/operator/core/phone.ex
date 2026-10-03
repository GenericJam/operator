defmodule Operator.Core.Phone do
  @moduledoc """
  Phone actions for tools (location, notifications, camera, photo picker).
  The mob plugins behind them deliver their results, and their permission
  dialogs, to the screen in front, so a tool can't call them itself: it
  asks the host screen (the chat screen, which registers on mount) with
  `request/3` and waits for the answer.

  Protocol: the tool's process sends the host
  `{:phone_request, ref, tool_pid, action, args}`; the host answers
  `{:phone_reply, ref, {:ok, result} | {:error, reason}}`.
  """

  @key {__MODULE__, :host}

  @type action :: :location | :notify | :camera_photo | :pick_photos

  @doc "Makes `pid` the screen that serves phone requests."
  @spec register_host(pid()) :: :ok
  def register_host(pid) when is_pid(pid) do
    if :persistent_term.get(@key, nil) != pid, do: :persistent_term.put(@key, pid)
    :ok
  end

  @doc "The host if it's alive."
  @spec host() :: pid() | nil
  def host do
    case :persistent_term.get(@key, nil) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  @doc "Asks the host to do `action` and waits up to `timeout` ms for the answer."
  @spec request(action(), map(), timeout(), pid() | nil) :: {:ok, term()} | {:error, String.t()}
  def request(action, args, timeout, host \\ host())

  def request(_action, _args, _timeout, nil),
    do: {:error, "The Operator chat screen isn't running, and phone actions go through it."}

  def request(action, args, timeout, host) do
    ref = Process.monitor(host)
    send(host, {:phone_request, ref, self(), action, args})

    receive do
      {:phone_reply, ^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _, _} ->
        {:error, "The chat screen went away before answering."}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "No answer from the phone within #{div(timeout, 1000)} s."}
    end
  end

  @doc "The host's answer to a request."
  @spec reply(pid(), reference(), {:ok, term()} | {:error, String.t()}) :: :ok
  def reply(pid, ref, result) do
    send(pid, {:phone_reply, ref, result})
    :ok
  end
end
