defmodule Operator.Diag do
  @moduledoc """
  Spike probes, run on the device (over dist rpc or from the home screen).
  Every function returns plain data and never includes a token.
  """

  alias Operator.Core.LLM.ReqLLM, as: Client

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

  @doc "Model catalog lookup of a model (the default one), timed."
  def llmdb(spec \\ Operator.Core.default_model()) do
    {us, res} = :timer.tc(fn -> ReqLLM.model(spec) end)

    case res do
      {:ok, m} ->
        %{
          ok: true,
          id: m.id,
          provider: m.provider,
          us: us,
          tools: get_in(m.capabilities, [:tools, :enabled]),
          provider_models: length(LLMDB.models(m.provider))
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

  # ── model calls (need a sign-in, Operator.Auth) ──

  @doc """
  One streamed completion with the provider's sign-in, as the agent loop
  calls it. Returns time-to-first-token, total time, chunk count, and the text.
  """
  def stream(model \\ Operator.Core.default_model()) do
    t0 = now()

    prompt = "Count from 1 to 10, one number per line, nothing else."
    request = %{model: model, system_prompt: "", messages: [], tools: [], max_tokens: 200}

    with {:ok, opts} <- Client.options(request, &Operator.Auth.access_token/1),
         {:ok, resp} <- ReqLLM.stream_text(model, prompt, opts) do
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
    else
      {:error, e} -> %{ok: false, model: model, error: describe(e), total_ms: now() - t0}
    end
  rescue
    e -> %{ok: false, model: model, error: Exception.message(e)}
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(e), do: inspect(e)

  defp to_string_or({:error, _} = e), do: inspect(e)
  defp to_string_or(path), do: to_string(path)

  defp now, do: System.monotonic_time(:millisecond)
end
