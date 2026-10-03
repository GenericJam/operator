# Operator plan

Operator is an omp/pi-shaped coding agent that runs on the phone (a mob app,
Elixir on device) and can rewrite its own Dyn layer safely. Design:
`docs/DESIGN.md` (accepted 2026-10-02). Feasibility: `docs/SPIKE.md`.

## Principles

- **The session is the agent.** A session is plain-text JSONL; whoever holds
  it can continue the conversation.
- **Sessions are omp/pi-compatible.** Operator reads and writes the same
  session format as omp/pi (`pi-coding-agent/src/session/session-entries.ts`,
  session version 3), so a session can be **sent from omp to the phone and
  back from the phone to omp** and continue where it left off.
- **Core fixed, Dyn self-editable**, every self-change behind biometric
  approval (see DESIGN.md).

## Session compatibility with omp/pi

Format (pi's, not our own):
- Line 1: `{"type":"session","version":3,"id","timestamp","cwd","title"}`.
- Entries: `{"type","id","parentId","timestamp", …}`; `message` entries carry
  pi's AgentMessage (`user`; `assistant` with `text` / `thinking` /
  `toolCall{id,name,arguments}` blocks plus `model`, `provider`, `usage`,
  `stopReason`; `toolResult{toolCallId,toolName,content,isError}`), plus
  `custom_message`, `model_change`, `compaction`.
- Entries Operator doesn't understand (omp's `custom`, `title_change`,
  `credential_pin`, …) are kept verbatim and ignored for context, so nothing
  is lost on a round trip.

What a transfer has to deal with:
1. **Tools differ by host.** omp's tools (bash, edit, lsp, …) don't exist on
   the phone and the phone's (camera, location, self-mod) don't exist in omp.
   History is fine (tool calls and results are just text); for new turns each
   host offers its own tools and tells the model what changed with a
   `custom_message` ("now on the phone: these tools are available").
2. **Models and providers differ.** The phone uses OpenRouter; omp may use a
   direct provider. A `model_change` entry is written on arrival; provider-
   specific fields (`responseId`, thinking signatures, cache metadata) are
   kept but not replayed to a different provider.
3. **Paths and environment.** `cwd` and file paths in the history refer to the
   original host; the arrival notice says so.
4. **Size.** omp sessions can be large: transfer the latest branch only, or a
   compacted session (summary + recent tail), with artifacts referenced, not
   inlined, unless requested.
5. **Secrets.** Never transfer credentials; omp entries like `credentialId`
   and `credential_pin` are dropped on export.

Transport options (to decide when we build it):
- **Muster** as the relay: "send this session to my phone" posts it as an
  attachment/card for the receiving side to pull (already authenticated on
  both ends, works across machines).
- **Direct**: dist/adb during development, a QR-paired local link later.
- An omp command/extension `/send-to-phone` and an Operator action
  "Send to omp" that produces a file omp can `--resume`.

## Build order

1. **Core loop** (in progress): pi's turn loop on req_llm (OpenRouter),
   steering/follow-up/stop, parallel tools with ordered results, omp/pi-format
   JSONL sessions, terminal-style chat screen (styled, streaming, stick to
   bottom). Verify on the Moto G.
2. **Self-modification**: generations with versioned module names, static
   check, selftests, biometric approval, probation, automatic revert, safe
   mode + rescue screen; agent-editable terminal theme as the first Dyn
   artifact.
3. **Phone tools, context management**: camera/photos/location/notifications/
   http; output budget + artifacts; compaction; cost cap.
4. **Session transfer omp ⇄ phone** (this document's compatibility section),
   starting with export/import files, then Muster as the relay.
5. Secure-store key, iOS build, foreground service for long runs.
