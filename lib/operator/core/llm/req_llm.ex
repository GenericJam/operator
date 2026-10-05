defmodule Operator.Core.LLM.ReqLLM do
  @moduledoc """
  Anthropic (Claude Pro/Max) and OpenAI Codex (ChatGPT Plus/Pro) through
  req_llm's providers, streamed, with the subscription's OAuth access token
  from `Operator.Auth` (fetched, and refreshed when due, per call):

    * `anthropic:` → `auth_mode: :oauth`, `access_token`,
      `with_claude_subscription: true` (Claude Code's betas and identity)
    * `openai_codex:` → `auth_mode: :oauth`, `access_token`,
      `chatgpt_account_id`, and the session id as `session_id` (the prompt
      cache key)

  A provider without a sign-in fails with `{:signed_out, provider}`; any
  other model prefix with `{:other, _}`. `max_tokens` is always explicit
  (req_llm's default is the model's whole output limit).
  """
  @behaviour Operator.Core.LLM

  alias Operator.Auth
  alias ReqLLM.StreamResponse

  @impl true
  def stream(request, _opts, sink) do
    case options(request, &Auth.access_token/1) do
      {:ok, opts} -> run(request, opts, sink)
      {:error, _normalized} = error -> error
    end
  end

  defp run(request, opts, sink) do
    context =
      ReqLLM.Context.new([ReqLLM.Context.system(request.system_prompt) | request.messages])

    with {:ok, stream} <- ReqLLM.stream_text(request.model, context, opts),
         {:ok, response} <-
           StreamResponse.process_stream(stream,
             on_result: &sink.({:text, &1}),
             on_thinking: &sink.({:thinking, &1})
           ) do
      {:ok, reply(response)}
    else
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  @doc false
  # req_llm's options for `request`: max_tokens, tools and the provider's
  # credentials from `access_token` (`Operator.Auth.access_token/1`).
  @spec options(Operator.Core.LLM.request(), (Auth.provider() -> term())) ::
          {:ok, keyword()} | {:error, Operator.Core.LLM.error()}
  def options(request, access_token) do
    # max_retries: 0: the loop retries (with its own bounded backoff). req_llm's
    # stream retry sleeps for a 429's retry-after, which on a subscription
    # limit is days: the call then died as a bare `:timeout` instead of the 429.
    base =
      [max_tokens: request.max_tokens, max_retries: 0] ++
        if(request.tools == [], do: [], else: [tools: request.tools])

    with {:ok, provider} <- provider(request.model),
         {:ok, auth} <- token(provider, access_token) do
      {:ok, base ++ [provider_options: provider_options(provider, auth, request)]}
    end
  end

  defp provider(model) do
    case Auth.provider_for_model(model) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        {:error,
         {:other,
          "Operator can't call #{model}: use an anthropic:… or openai_codex:… model " <>
            "(menu › model)."}}
    end
  end

  defp token(provider, access_token) do
    case access_token.(provider) do
      {:ok, %{token: _} = auth} ->
        {:ok, auth}

      {:error, :signed_out} ->
        {:error, {:signed_out, provider}}

      {:error, {:refresh_failed, message}} ->
        {:error, {:auth, provider, message}}

      {:error, {:store_failed, reason}} ->
        {:error,
         {:other,
          "the refreshed #{Auth.label(provider)} sign-in couldn't be saved " <>
            "(#{Auth.describe_error(reason)}); Operator keeps retrying, try again in a moment."}}
    end
  end

  defp provider_options(:anthropic, auth, _request),
    do: [auth_mode: :oauth, access_token: auth.token, with_claude_subscription: true]

  defp provider_options(:openai_codex, auth, request) do
    [
      auth_mode: :oauth,
      access_token: auth.token,
      chatgpt_account_id: auth.account_id,
      session_id: request[:session_id]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reply(response) do
    message = response.message

    %{
      text: ReqLLM.Response.text(response) || "",
      thinking: ReqLLM.Response.thinking(response) || "",
      tool_calls:
        for call <- ReqLLM.Response.tool_calls(response) do
          %{
            "id" => call.id,
            "name" => call.function.name,
            "arguments" => decode_args(call.function.arguments)
          }
        end,
      usage: response.usage,
      finish_reason: response.finish_reason || (message && :stop)
    }
  end

  defp decode_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> args
      _ -> %{"_raw" => json}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  @doc false
  @spec normalize(term()) :: Operator.Core.LLM.error()
  def normalize(%ReqLLM.Error.API.Request{status: status} = e) when is_integer(status),
    do: {:http, status, to_string(e.reason)}

  def normalize(%ReqLLM.Error.API.Response{status: status} = e) when is_integer(status),
    do: {:http, status, to_string(e.reason)}

  # A failure mid-stream is raised as a Stream error wrapping the real one
  # (its message inspects the whole cause, response headers included).
  def normalize(%ReqLLM.Error.API.Stream{cause: cause}) when cause != nil, do: normalize(cause)

  def normalize(%{__struct__: mod, reason: reason})
      when mod in [Mint.TransportError, Req.TransportError, Finch.TransportError, Finch.Error],
      do: {:transport, reason}

  def normalize(%{__exception__: true} = e), do: {:other, Exception.message(e)}
  def normalize({:http_task_failed, reason}), do: normalize(reason)
  def normalize(other), do: {:other, inspect(other, limit: 20, printable_limit: 500)}
end
