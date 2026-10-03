defmodule Operator.Test.FakeLLM do
  @moduledoc """
  A scripted `Operator.Core.LLM`: each model call takes the next reply from
  the script and plays its steps, streaming through the loop's sink.

  Steps: `{:text, s}`, `{:thinking, s}`, `{:tool_call, id, name, args}`,
  `{:sleep, ms}`, `:block` (never returns; the loop must kill it),
  `{:error, error}` (returns it), `{:usage, map}`, `{:finish, reason}`.

  Every call sends the test `{:llm_request, request, worker_pid}`.
  """
  @behaviour Operator.Core.LLM

  @spec start([[term()]], pid()) :: {:ok, pid()}
  def start(script, test \\ self()),
    do: Agent.start_link(fn -> %{script: script, requests: [], test: test} end)

  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @impl true
  def stream(request, agent, sink) do
    {reply, test} =
      Agent.get_and_update(agent, fn
        %{script: [reply | rest]} = st ->
          {{reply, st.test}, %{st | script: rest, requests: st.requests ++ [request]}}

        %{script: []} = st ->
          {{:exhausted, st.test}, %{st | requests: st.requests ++ [request]}}
      end)

    send(test, {:llm_request, request, self()})

    case reply do
      :exhausted ->
        {:error, {:other, "fake script exhausted"}}

      steps ->
        play(steps, sink, %{
          text: "",
          thinking: "",
          tool_calls: [],
          usage: default_usage(),
          finish_reason: :stop
        })
    end
  end

  defp play([], _sink, acc), do: {:ok, acc}

  defp play([step | rest], sink, acc) do
    case step do
      {:text, s} ->
        sink.({:text, s})
        play(rest, sink, %{acc | text: acc.text <> s})

      {:thinking, s} ->
        sink.({:thinking, s})
        play(rest, sink, %{acc | thinking: acc.thinking <> s})

      {:tool_call, id, name, args} ->
        play(rest, sink, %{
          acc
          | tool_calls: acc.tool_calls ++ [%{"id" => id, "name" => name, "arguments" => args}]
        })

      {:sleep, ms} ->
        Process.sleep(ms)
        play(rest, sink, acc)

      :block ->
        Process.sleep(:infinity)

      {:error, error} ->
        {:error, error}

      {:usage, usage} ->
        play(rest, sink, %{acc | usage: usage})

      {:finish, reason} ->
        play(rest, sink, %{acc | finish_reason: reason})
    end
  end

  defp default_usage, do: %{input_tokens: 100, output_tokens: 20, total_cost: 0.001}
end

defmodule Operator.Test.Tools.Echo do
  @moduledoc "Test tool: returns `text` after `sleep_ms`."
  @behaviour Operator.Core.Tool

  @impl true
  def name, do: "echo"
  @impl true
  def description, do: "Echo text back."
  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl true
  def run(args, _ctx) do
    Process.sleep(args["sleep_ms"] || 0)
    {:ok, args["text"] || ""}
  end
end

defmodule Operator.Test.Tools.Crash do
  @moduledoc "Test tool: raises."
  @behaviour Operator.Core.Tool

  @impl true
  def name, do: "crash"
  @impl true
  def description, do: "Always raises."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(_args, _ctx), do: raise("boom")
end

defmodule Operator.Test.Tools.Slow do
  @moduledoc "Test tool: outlives its 50 ms timeout."
  @behaviour Operator.Core.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Never finishes in time."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def timeout_ms, do: 50
  @impl true
  def run(_args, _ctx) do
    Process.sleep(5_000)
    {:ok, "too late"}
  end
end
