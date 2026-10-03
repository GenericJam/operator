defmodule Operator.Core.LLM.ReqLLM do
  @moduledoc """
  OpenRouter through req_llm's provider, streamed. The key
  is the one `Operator.KeyStore` handed to req_llm at boot / sign-in.
  `max_tokens` is always explicit (req_llm's 64k default gets a 402 on a
  small balance; see docs/SPIKE.md).
  """
  @behaviour Operator.Core.LLM

  alias ReqLLM.StreamResponse

  @impl true
  def stream(request, _opts, sink) do
    context =
      ReqLLM.Context.new([ReqLLM.Context.system(request.system_prompt) | request.messages])

    opts =
      [max_tokens: request.max_tokens] ++
        if(request.tools == [], do: [], else: [tools: request.tools])

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
