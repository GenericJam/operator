defmodule Operator.Core.LLM do
  @moduledoc """
  The model client the loop talks to. `Operator.Core.LLM.ReqLLM` is the real
  one (OpenRouter through req_llm); tests inject a scripted fake.

  `stream/3` runs in a process the loop owns (and kills on Stop). It calls
  `sink` for every streamed delta and returns the whole reply:

    * events: `{:text, delta}`, `{:thinking, delta}`
    * `{:ok, %{text:, thinking:, tool_calls: [%{"id", "name", "arguments"}],
       usage: map | nil, finish_reason: atom}}`
    * `{:error, error}` where `error` is normalized: `{:http, status, message}`,
      `{:transport, reason}` or `{:other, message}`
  """

  @type request :: %{
          model: String.t(),
          system_prompt: String.t(),
          messages: [ReqLLM.Message.t()],
          tools: [ReqLLM.Tool.t()],
          max_tokens: pos_integer()
        }
  @type error :: {:http, integer(), String.t()} | {:transport, term()} | {:other, String.t()}
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
    "OpenRouter 402 (payment required): #{message}\n" <>
      "Add credits at https://openrouter.ai/settings/credits, or lower max_tokens for this model."
  end

  def describe({:http, 401, message}),
    do: "OpenRouter 401 (key rejected): #{message}\nSign in again from Diagnostics."

  def describe({:http, 429, message}), do: "OpenRouter 429 (rate limited): #{message}"
  def describe({:http, status, message}), do: "Model call failed (HTTP #{status}): #{message}"

  def describe({:transport, reason}),
    do: "Network error talking to OpenRouter: #{inspect(reason)}"

  def describe({:other, message}), do: "Model call failed: #{message}"
end
