defmodule Operator.Core.Phone do
  @moduledoc """
  Phone actions for tools (location, notifications, the camera, the photo
  and file pickers, permissions). The pickers and the system camera are
  activities started from the screen in front, and the permission
  dialogs answer the process that asked; the chat screen (registered on
  mount) does both for tools: a tool asks it with `request/3` and waits
  for the answer. `:permission` (`%{capability: atom}`) asks for one
  permission, and answers `{:ok, :granted}` or an error the model can act on.

  Protocol: the tool's process sends the host
  `{:phone_request, ref, tool_pid, action, args}`; the host answers
  `{:phone_reply, ref, {:ok, result} | {:error, reason}}`.
  """

  @key {__MODULE__, :host}

  @type action ::
          :location
          | :notify
          | :camera_photo
          | :camera_snap
          | :pick_photos
          | :pick_file
          | :permission

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
