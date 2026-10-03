defmodule Operator.Test.ObserverHelpers do
  @moduledoc """
  An unnamed `Operator.Core.Current` (own loop supervisor) whose loops run on
  a scripted fake LLM, for testing the observers that watch it
  (`Operator.Core.KeepAlive`, `Operator.Core.Voice`).
  """

  import ExUnit.Callbacks

  alias Operator.Core.Current
  alias Operator.Test.FakeLLM

  @doc """
  Starts Current over `dir`; returns `%{current, llm}`. `loop_opts` go to
  every loop. `name` registers it (nil: unnamed; `Operator.Core.Current`
  for code that reaches the app-wide one).
  """
  def start_current(dir, script, loop_opts \\ [], name \\ nil) do
    {:ok, llm} = FakeLLM.start(script)
    tasks = start_supervised!(Task.Supervisor, id: make_ref())
    loop_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: make_ref())

    loop_opts =
      [
        llm: {FakeLLM, llm},
        tools: [Operator.Test.Tools.Echo],
        task_supervisor: tasks,
        data_dir: dir,
        system_prompt: "test",
        retry_base_ms: 1
      ] ++ loop_opts

    current =
      start_supervised!(
        {Current, name: name, dir: dir, loop_sup: loop_sup, loop_opts: loop_opts},
        id: make_ref()
      )

    %{current: current, llm: llm}
  end

  @doc "Starts an observer `module` watching `current`; returns once it has watched."
  def start_observer(module, current, opts) do
    pid = start_supervised!({module, [name: nil, current: current] ++ opts}, id: make_ref())
    # handle_continue(:watch) runs before any later message.
    _ = :sys.get_state(pid)
    pid
  end
end

defmodule Operator.Test.FakeKeepAlive do
  @moduledoc """
  `Operator.Core.KeepAlive.Backend` reporting `{:keep_alive, :on | :off}` to
  a pid. Arg: `pid`, `{:error, pid}` (reports, then fails) or `{:raise, pid}`.
  """
  @behaviour Operator.Core.KeepAlive.Backend

  @impl true
  def keep_alive(arg), do: report(arg, :on)

  @impl true
  def stop(arg), do: report(arg, :off)

  defp report({:error, pid}, what) do
    send(pid, {:keep_alive, what})
    {:error, :boom}
  end

  defp report({:raise, pid}, what) do
    send(pid, {:keep_alive, what})
    raise "boom"
  end

  defp report(pid, what) do
    send(pid, {:keep_alive, what})
    :ok
  end
end

defmodule Operator.Test.FakeSpeech do
  @moduledoc """
  `Operator.Core.Voice.Speech` reporting `{:speak, text}` / `:speech_stop` to
  a pid. Arg: `pid`, `{:error, pid}` (reports, then fails) or `{:raise, pid}`.
  """
  @behaviour Operator.Core.Voice.Speech

  @impl true
  def speak(arg, text), do: report(arg, {:speak, text})

  @impl true
  def stop(arg), do: report(arg, :speech_stop)

  defp report({:error, pid}, message) do
    send(pid, message)
    {:error, :boom}
  end

  defp report({:raise, pid}, message) do
    send(pid, message)
    raise "boom"
  end

  defp report(pid, message) do
    send(pid, message)
    :ok
  end
end
