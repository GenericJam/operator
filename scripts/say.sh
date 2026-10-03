#!/usr/bin/env bash
# Type a message into the running ChatScreen and press Send (device testing).
# Usage: OPERATOR_SERIAL=<serial> scripts/say.sh "message text"
set -euo pipefail
cd "$(dirname "$0")/.."
msg=$(printf '%s' "$1" | base64)
scripts/rpc.sh "t = Base.decode64!(\"$msg\"); send({:mob_screen, n}, {:change, :draft, t}); Process.sleep(300); send({:mob_screen, n}, {:tap, :send}); IO.puts(\"sent\")"
