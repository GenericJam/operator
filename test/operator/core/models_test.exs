defmodule Operator.Core.ModelsTest do
  # async: false: the sign-ins (Operator.Auth) are app-wide.
  use ExUnit.Case, async: false

  alias Operator.Auth
  alias Operator.Core.Models

  @creds %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}

  setup do
    start_supervised!(Auth)
    on_exit(fn -> for p <- Auth.providers(), do: Operator.SecureStore.delete("auth:#{p}") end)
  end

  test "ChatGPT signed in: omp's Codex models are listed" do
    :ok = Auth.put(:anthropic, @creds)
    :ok = Auth.put(:openai_codex, @creds)

    assert [{:anthropic, true, [_ | _]}, {:openai_codex, true, codex}] = Models.by_provider()

    assert Enum.any?(codex, &(&1.spec == "openai_codex:gpt-5.5"))
    refute Enum.any?(codex, &String.contains?(&1.spec, "image"))
    assert Models.same?("anthropic:claude-haiku-4-5", "anthropic:claude-haiku-4-5-20251001")
  end
end
