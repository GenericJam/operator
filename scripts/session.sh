#!/usr/bin/env bash
# Debugging only: move whole session files between the phone and omp (they're
# the same pi JSONL format). To carry work from omp to the phone, use a
# handoff instead: /handoff in omp, then `mix operator.handoff` shows it as QR
# codes the phone scans (Operator.Handoff). A transferred transcript assumes
# omp's tools (bash, the Mac's files), which the phone doesn't have.
#
#   OPERATOR_SERIAL=<serial> scripts/session.sh pull [id-prefix]
#       Copies the phone's latest session (or the one whose id starts with
#       the prefix) into omp's sessions dir and prints the omp command that
#       resumes it.
#   OPERATOR_SERIAL=<serial> scripts/session.sh push <session.jsonl>
#       Copies an omp session onto the phone and opens it in the chat
#       screen (the app must be running and connected: mix mob.connect).
#
# The phone keeps its own copy: each side appends to its own file, so after
# working on one side, pull/push again to carry on on the other.
set -euo pipefail
cd "$(dirname "$0")/.."
SERIAL="${OPERATOR_SERIAL:-emulator-5554}"
PKG=com.genericjam.operator
PHONE_DIR=files/sessions
OMP_DIR="${OMP_SESSIONS_DIR:-$HOME/.omp/agent/sessions/--operator-phone--}"

phone() { adb -s "$SERIAL" exec-out run-as "$PKG" "$@"; }

case "${1:-}" in
  pull)
    prefix="${2:-}"
    # Newest first: the files are named <timestamp>_<id>.jsonl.
    name=$(phone ls "$PHONE_DIR" | tr -d '\r' | grep -E '\.jsonl$' | grep -E "_${prefix}" | sort -r | head -1)
    [ -n "$name" ] || { echo "no session on the phone matches '${prefix}'" >&2; exit 1; }
    mkdir -p "$OMP_DIR"
    phone cat "$PHONE_DIR/$name" > "$OMP_DIR/$name"
    echo "pulled $(wc -l < "$OMP_DIR/$name" | tr -d ' ') entries to $OMP_DIR/$name"
    echo "resume it in omp:  omp --resume $OMP_DIR/$name"
    ;;
  push)
    src="${2:?usage: session.sh push <session.jsonl>}"
    # omp puts a title slot line before the session header.
    head -2 "$src" | grep -q '"type":"session"' || { echo "$src is not a pi/omp session file" >&2; exit 1; }
    name=$(basename "$src")
    tmp="/data/local/tmp/operator-$name"
    adb -s "$SERIAL" push "$src" "$tmp" >/dev/null
    adb -s "$SERIAL" shell chmod 644 "$tmp"
    phone mkdir -p "$PHONE_DIR"
    phone cp "$tmp" "$PHONE_DIR/$name"
    adb -s "$SERIAL" shell rm "$tmp"
    data=$(phone pwd | tr -d '\r')
    OPERATOR_SERIAL="$SERIAL" scripts/rpc.sh "
      host = :rpc.call(n, Operator.Core.Phone, :host, [])
      if is_pid(host) do
        send(host, {:open_session, \"$data/$PHONE_DIR/$name\"})
        IO.puts(\"opened $name in the chat screen\")
      else
        IO.puts(\"copied $name; open the chat screen and run: Operator.Core.open_session(\\\"$data/$PHONE_DIR/$name\\\")\")
      end"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
