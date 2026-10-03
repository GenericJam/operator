#!/usr/bin/env bash
# Probe Android's background network restriction (device testing).
# Usage: OPERATOR_SERIAL=<serial> scripts/bgnet.sh <keepalive:on|off> <seconds>
# Backgrounds the app (screen off), waits, then makes one HTTPS request from
# the app's BEAM and prints whether it got through.
set -euo pipefail
cd "$(dirname "$0")/.."
serial="${OPERATOR_SERIAL:?set OPERATOR_SERIAL}"
mode="$1"; secs="$2"
if [ "$mode" = on ]; then
  scripts/rpc.sh 'IO.inspect(:rpc.call(n, MobBackground, :keep_alive, []), label: "keep_alive")'
else
  scripts/rpc.sh 'IO.inspect(:rpc.call(n, MobBackground, :stop, []), label: "stop")'
fi
adb -s "$serial" shell input keyevent KEYCODE_HOME
adb -s "$serial" shell input keyevent KEYCODE_SLEEP
sleep "$secs"
scripts/rpc.sh '
f = fn ->
  t0 = System.monotonic_time(:millisecond)
  r = Req.get("https://api.anthropic.com/v1/models", retry: false, receive_timeout: 15_000, connect_options: [timeout: 15_000])
  ms = System.monotonic_time(:millisecond) - t0
  case r do
    {:ok, %{status: s}} -> {:ok, s, ms}
    {:error, e} -> {:error, Exception.message(e), ms}
  end
end
IO.inspect(:rpc.call(n, :erlang, :apply, [f, []], 40_000), label: "https after background")'
fg=$(adb -s "$serial" shell dumpsys activity services com.genericjam.operator | grep -c 'isForeground=true' || true)
echo "foreground services running: $fg"
adb -s "$serial" shell input keyevent KEYCODE_WAKEUP
