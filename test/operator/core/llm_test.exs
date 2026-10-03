defmodule Operator.Core.LLMTest do
  use ExUnit.Case, async: true

  alias Operator.Core.LLM
  alias Operator.Core.LLM.ReqLLM, as: Adapter

  test "a 402 raised mid-stream reads as the short payment message, without the response" do
    cause = %ReqLLM.Error.API.Request{
      status: 402,
      reason: "You requested up to 4096 tokens, but can only afford 2791.",
      response_body: %{"code" => 402},
      headers: [{"set-cookie", "__cf_bm=secret"}]
    }

    error =
      Adapter.normalize(%ReqLLM.Error.API.Stream{reason: "Stream failed: ...", cause: cause})

    assert error == {:http, 402, "You requested up to 4096 tokens, but can only afford 2791."}

    text = LLM.describe(error)
    assert text =~ "OpenRouter 402 (payment required): You requested up to 4096 tokens"
    assert text =~ "openrouter.ai/settings/credits"
    refute text =~ "cookie"
  end
end
