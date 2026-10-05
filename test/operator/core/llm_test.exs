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
    assert text =~ "402 (payment required): You requested up to 4096 tokens"
    assert text =~ "lower max_tokens"
    refute text =~ "cookie"
  end

  describe "req_llm options per model prefix" do
    defp request(model, extra \\ %{}),
      do:
        Map.merge(
          %{model: model, system_prompt: "", messages: [], tools: [], max_tokens: 99},
          extra
        )

    defp signed_in(provider, token, account \\ nil) do
      fn
        ^provider -> {:ok, %{token: token, account_id: account}}
        _other -> {:error, :signed_out}
      end
    end

    test "anthropic: the subscription's OAuth token, Claude Code mode" do
      assert {:ok, opts} =
               Adapter.options(
                 request("anthropic:claude-haiku-4-5"),
                 signed_in(:anthropic, "at-1")
               )

      assert opts[:max_tokens] == 99
      # The loop owns retries: a 429 must come back as itself, not after
      # req_llm sleeps out its retry-after.
      assert opts[:max_retries] == 0
      refute Keyword.has_key?(opts, :tools)

      assert opts[:provider_options] == [
               auth_mode: :oauth,
               access_token: "at-1",
               with_claude_subscription: true
             ]
    end

    test "openai_codex: token, ChatGPT account and the session as session_id" do
      req = request("openai_codex:gpt-5", %{session_id: "s-1"})

      assert {:ok, opts} = Adapter.options(req, signed_in(:openai_codex, "at-2", "acct-9"))

      assert opts[:provider_options] == [
               auth_mode: :oauth,
               access_token: "at-2",
               chatgpt_account_id: "acct-9",
               session_id: "s-1"
             ]

      # no session (a compaction request), no account id: just left out
      assert {:ok, opts} =
               Adapter.options(request("openai_codex:gpt-5"), signed_in(:openai_codex, "at-2"))

      assert opts[:provider_options] == [auth_mode: :oauth, access_token: "at-2"]
    end

    test "a signed-out provider or a dead refresh says to sign in from the menu; other prefixes are refused" do
      assert {:error, {:signed_out, :openai_codex} = e} =
               Adapter.options(request("openai_codex:gpt-5"), signed_in(:anthropic, "x"))

      assert LLM.describe(e) =~ "sign in from [menu] › accounts"
      refute LLM.retryable?(e)

      dead = fn :anthropic -> {:error, {:refresh_failed, "400 invalid_grant"}} end

      assert {:error, {:auth, :anthropic, "400 invalid_grant"} = e} =
               Adapter.options(request("anthropic:claude-haiku-4-5"), dead)

      assert LLM.describe(e) =~ "400 invalid_grant"
      assert LLM.describe(e) =~ "sign in again from [menu] › accounts"

      assert {:error, {:other, message}} =
               Adapter.options(request("openai:gpt-5"), signed_in(:anthropic, "x"))

      assert message =~ "can't call openai:gpt-5"
    end
  end
end
