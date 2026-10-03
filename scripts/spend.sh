#!/usr/bin/env bash
# Print the OpenRouter key's usage (USD) as seen from the phone. Never prints
# the key. Usage: OPERATOR_SERIAL=<serial> scripts/spend.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/rpc.sh '
f = fn ->
  key = Application.get_env(:req_llm, :openrouter_api_key)
  case Req.get("https://openrouter.ai/api/v1/key", headers: [{"authorization", "Bearer " <> key}], retry: false) do
    {:ok, %{status: 200, body: %{"data" => d}}} -> Map.take(d, ["usage", "limit", "limit_remaining", "is_free_tier"])
    {:ok, r} -> {:http, r.status}
    {:error, e} -> {:error, Exception.message(e)}
  end
end
IO.inspect(:rpc.call(n, :erlang, :apply, [f, []], 30_000), label: "openrouter key")' | grep -v -i 'sk-or'
