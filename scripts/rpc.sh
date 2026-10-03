#!/usr/bin/env bash
# Evaluate Elixir on the running Operator app over dist (Android).
#
#   mix mob.connect --no-iex --no-restart --only <serial>   # once: adb forwards
#   scripts/rpc.sh 'IO.inspect(:rpc.call(n, Operator.Diag, :all, []))'
#
# `n` is bound to the device node, operator_android_<serial>@127.0.0.1 (the
# name mob.connect prints). Pick the device with OPERATOR_SERIAL (default
# emulator-5554) or the node with OPERATOR_NODE. Recipe from muster_app
# docs/HANDOFF.md. Never `adb forward tcp:4369`: it hijacks the Mac's epmd.
set -euo pipefail
cd "$(dirname "$0")/.."
SERIAL="${OPERATOR_SERIAL:-emulator-5554}"
SUFFIX="$(echo "$SERIAL" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '_')"
N="${OPERATOR_NODE:-operator_android_${SUFFIX}@127.0.0.1}"
MIX_ENV=dev elixir --name "drv$RANDOM@127.0.0.1" -S mix run --no-start --no-compile \
  -e "Node.set_cookie(MobDev.DistCookie.for_project!()); n = :\"$N\"; true = Node.connect(n); $1" \
  2>&1 | grep -vE "dlopen|mob_nif|load_failed|^\{:error,$|^\s*$" || true
