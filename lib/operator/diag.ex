defmodule Operator.Diag do
  @moduledoc """
  Spike probes, run on the device (over dist rpc or from the home screen).
  Every function returns plain data and never includes the OpenRouter key.
  """

  @agent_apps [:jido, :jido_signal, :jido_action, :jido_ai, :req_llm, :llm_db, :finch, :req]

  @doc "Which of the agent stack's applications are running."
  def apps do
    running = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    Map.new(@agent_apps ++ [:mnesia, :compiler], &{&1, MapSet.member?(running, &1)})
  end

  @doc "Is everything on-device compilation needs present?"
  def compiler do
    %{
      compiler_lib_dir: to_string_or(:code.lib_dir(:compiler)),
      compile_module: Code.ensure_loaded?(:compile),
      v3_core: Code.ensure_loaded?(:v3_core),
      beam_asm: Code.ensure_loaded?(:beam_asm),
      elixir_compiler: Code.ensure_loaded?(:elixir_compiler),
      elixir_erl: Code.ensure_loaded?(:elixir_erl),
      elixir_expand: Code.ensure_loaded?(:elixir_expand),
      kernel_parallel_compiler: Code.ensure_loaded?(Kernel.ParallelCompiler),
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version()
    }
  end

  @doc "LLMDB lookup of a model, timed."
  def llmdb(spec \\ "openrouter:anthropic/claude-haiku-4.5") do
    {us, res} = :timer.tc(fn -> LLMDB.model(spec) end)

    case res do
      {:ok, m} ->
        %{
          ok: true,
          id: m.id,
          provider: m.provider,
          us: us,
          tools: get_in(m.capabilities, [:tools, :enabled]),
          openrouter_models: length(LLMDB.models(:openrouter))
        }

      other ->
        %{ok: false, result: inspect(other), us: us}
    end
  end

  @doc "Start the Jido.AI agent (no network) and report its state."
  def agent do
    {us, res} = :timer.tc(fn -> Operator.Jido.start_agent(Operator.Agent) end)

    case res do
      {:ok, pid} ->
        {:ok, st} = Jido.AgentServer.state(pid)
        tools = Jido.AI.list_tools(pid)

        info = %{
          ok: true,
          alive: Process.alive?(pid),
          start_us: us,
          agent_id: st.agent.id,
          tools: inspect(tools)
        }

        Operator.Jido.stop_agent(pid)
        info

      other ->
        %{ok: false, result: inspect(other)}
    end
  end

  @doc "All step-2 probes in one map."
  def all,
    do: %{
      apps: apps(),
      compiler: compiler(),
      llmdb: llmdb(),
      agent: agent(),
      boot: Operator.Boot.timings()
    }

  # ── model calls (need the key) ──

  @doc """
  One streamed completion through req_llm's openrouter provider.
  Returns time-to-first-token, total time, chunk count, and the text.
  """
  def stream(model \\ "openrouter:google/gemma-4-31b-it:free") do
    t0 = now()

    prompt = "Count from 1 to 10, one number per line, nothing else."

    case ReqLLM.stream_text(model, prompt, max_tokens: 200) do
      {:ok, resp} ->
        {ttft, chunks, text} =
          resp
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce({nil, 0, ""}, fn tok, {first, n, acc} ->
            {first || now() - t0, n + 1, acc <> tok}
          end)

        %{
          ok: true,
          model: model,
          ttft_ms: ttft,
          total_ms: now() - t0,
          chunks: chunks,
          text: text,
          usage: ReqLLM.StreamResponse.usage(resp)
        }

      {:error, e} ->
        %{ok: false, model: model, error: describe(e), total_ms: now() - t0}
    end
  rescue
    e -> %{ok: false, model: model, error: Exception.message(e)}
  end

  def tool_roundtrip(model \\ "openrouter:google/gemma-4-31b-it:free") do
    Application.put_env(:jido_ai, :model_aliases, %{operator: model})
    {:ok, pid} = Operator.Jido.start_agent(Operator.Agent)
    t0 = now()

    res =
      Operator.Agent.ask_sync(
        pid,
        "Use the add_numbers tool to compute 1234 + 4321. Reply with just the number.",
        timeout: 120_000
      )

    ms = now() - t0
    {:ok, st} = Jido.AgentServer.state(pid)
    Operator.Jido.stop_agent(pid)

    %{
      model: model,
      ms: ms,
      result: inspect(res, limit: 50, printable_limit: 500),
      tool_results:
        inspect(get_in(st.agent.state, [:__strategy__, :details, :tool_results]) || :n_a)
    }
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(e), do: inspect(e)

  defp to_string_or({:error, _} = e), do: inspect(e)
  defp to_string_or(path), do: to_string(path)

  defp now, do: System.monotonic_time(:millisecond)
end
