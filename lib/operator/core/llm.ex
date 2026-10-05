defmodule Operator.Core.LLM do
  @moduledoc """
  The model client the loop talks to. `Operator.Core.LLM.ReqLLM` is the real
  one (Anthropic / OpenAI Codex through req_llm, signed in with
  `Operator.Auth`); tests inject a scripted fake.

  `stream/3` runs in a process the loop owns (and kills on Stop). It calls
  `sink` for every streamed delta and returns the whole reply:

    * events: `{:text, delta}`, `{:thinking, delta}`
    * `{:ok, %{text:, thinking:, tool_calls: [%{"id", "name", "arguments"}],
       usage: map | nil, finish_reason: atom}}`
    * `{:error, error}` where `error` is normalized: `{:http, status, message}`,
      `{:transport, reason}`, `{:signed_out, provider}` (no sign-in for the
      model's provider), `{:auth, provider, message}` (its token couldn't be
      refreshed) or `{:other, message}`
  """

  @type request :: %{
          required(:model) => String.t(),
          required(:system_prompt) => String.t(),
          required(:messages) => [ReqLLM.Message.t()],
          required(:tools) => [ReqLLM.Tool.t()],
          required(:max_tokens) => pos_integer(),
          optional(:session_id) => String.t()
        }
  @type error ::
          {:http, integer(), String.t()}
          | {:transport, term()}
          | {:signed_out, Operator.Auth.provider()}
          | {:auth, Operator.Auth.provider(), String.t()}
          | {:other, String.t()}
  @type reply :: %{
          text: String.t(),
          thinking: String.t(),
          tool_calls: [map()],
          usage: map() | nil,
          finish_reason: atom() | nil
        }

  @callback stream(request(), opts :: term(), sink :: (term() -> any())) ::
              {:ok, reply()} | {:error, error()}

  @doc "Worth retrying: rate limits, provider 5xx, dropped connections."
  @spec retryable?(error()) :: boolean()
  def retryable?({:http, 429, _}), do: true
  def retryable?({:http, status, _}) when status >= 500, do: true
  def retryable?({:transport, _}), do: true
  def retryable?(_), do: false

  @doc "What the user sees for a failed call, with the remedy where there is one."
  @spec describe(error()) :: String.t()
  def describe({:http, 402, message}) do
    "402 (payment required): #{message}\n" <>
      "Check your plan's usage limits, or lower max_tokens for this model."
  end

  def describe({:http, 401, message}),
    do: "401 (sign-in rejected): #{message}\nSign in again: [menu] › accounts."

  def describe({:http, 429, message}), do: "429 (rate limited): #{message}"
  def describe({:http, status, message}), do: "Model call failed (HTTP #{status}): #{message}"

  def describe({:transport, reason}),
    do: "Network error talking to the model provider: #{inspect(reason)}"

  def describe({:signed_out, provider}) do
    "Not signed in to #{Operator.Auth.label(provider)}: " <>
      "sign in from [menu] › accounts."
  end

  def describe({:auth, provider, message}) do
    "#{Operator.Auth.label(provider)} sign-in expired (#{message}): " <>
      "sign in again from [menu] › accounts."
  end

  def describe({:other, message}), do: "Model call failed: #{message}"
end
