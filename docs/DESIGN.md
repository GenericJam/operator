# Operator design: an omp-shaped agent that rewrites itself on the phone

Status: **accepted 2026-10-02** by Kevin: Core fixed (changed only by a
release from the Mac), Dyn self-editable; every self-change needs biometric
approval in v1. Builds on `docs/SPIKE.md` (on-device compile 0.1–0.3 s,
persisted sources recompile at boot, OpenRouter sign-in, streaming and tool
calls via req_llm on a Moto G 2021).

## 1. The core idea: a fixed core that can always repair a mutable layer

sloppy_joe survives self-modification with two BEAM nodes: the phone runs the
mutable canvas; an off-phone Control Node holds last-known-good code, never
runs the canvas's code, and reverts it. pi/omp survives it in one process:
its core loop is fixed, all self-augmentation goes through **extensions**
whose load errors are collected rather than thrown, whose registrations are
checkpointed and rolled back when a factory throws, and whose handlers run
inside try/catch (`pi-coding-agent/src/extensibility/extensions/loader.ts`).

On a phone, two nodes are mostly unavailable: one ERTS per OS process, iOS
can't start a second process at all, and Android's second-process design
(`sloppy_joe/docs/phase2_second_process.md`) is unproven. So Operator takes
**pi's shape inside one BEAM, with sloppy_joe's guarantees moved in-process**:

- **Core** (shipped in the app binary, never written by the agent): boot, the
  agent loop, the session store, the core tools (read/write/compile/test/
  activate/revert), sign-in, the approval gate, safe mode and the rescue
  screen. The Core plays the Control Node's role: it never runs as mutable
  code, so a broken mutable layer can never remove the ability to repair it.
- **Dyn** (written by the agent, on device): screens, tools, prompts and
  *policies* (hooks on the loop, like pi extensions). Everything the agent
  changes lives here.

The agent can change its own behaviour a lot (new tools, new screens, new
system prompt sections, hooks that reshape each turn), but not the loop or
the repair path. Changing the Core is a normal release from the Mac (cable or
OTA with mob_deliver), never a self-edit.

## 2. Self-modification without crashing

### Generations, not files
Every accepted change produces a **generation**: the full Dyn source set, its
compiled BEAM hashes, test results, a diff and a one-line rationale. Stored
under the app's data dir as `gens/<n>/` plus a `current` pointer. Activation
is an atomic pointer flip; old generations are kept (revert = flip back).

### Versioned module names (no purge hazards)
Loading a new version of a module the BEAM already runs turns the running
code into "old" code; loading again purges it and **kills every process still
executing it**. Operator avoids that entirely: generation *n* compiles its
modules under `Operator.Dyn.G<n>.*` (the agent writes `Operator.Dyn.Foo`; the
Core rewrites the namespace at compile time). A candidate generation loads
next to the running one, never over it. A registry (one ETS table owned by the
Core) maps logical names (tool `weather`, screen `Notes`, hook
`transform_context`) to the module of the current generation. Switching
generations swaps registry entries; old generations' modules are unloaded
only once nothing references them.

### The pipeline (each step can refuse; nothing live changes until step 6)
1. **Write**: the agent edits sources in a staging copy of the current
   generation (Core tools; hashline-anchored edits as in omp).
2. **Static check**: parse the source; reject modules outside the Dyn
   namespace, and calls to `:code`, `System.halt/stop`, `:erlang.halt`,
   `File`/`Path` outside the generation dir, Core modules' internals,
   `Mob.Dist`, etc. Defence in depth, not a sandbox.
3. **Compile** into `Operator.Dyn.G<n+1>.*` (`Code.compile_string/2`, the
   spike measured 0.1–0.3 s).
4. **Selftest** each module in a fresh process with `max_heap_size`, a
   timeout, and `trap_exit`: screens must mount + render, tools must pass
   their own `selftest/0`, hooks get a canned request. Any failure stops here.
5. **Approval**: a card with the diff, rationale and test results; Kevin
   approves with **biometrics** (deny needs no biometric). Small policy
   changes can be configured to auto-approve later; not in v1.
6. **Activate** (registry swap + `current` pointer) under **probation**: the
   generation is "unproven" until it has run for a while (first render of
   each changed screen, N successful tool calls, or 60 s without a Dyn crash)
   and survived one app restart.
7. **Revert automatically** if, while unproven: a Dyn process crashes
   repeatedly (a Keeper counts crashes per generation, like sloppy_joe's
   CanvasKeeper: 3 in 60 s), or the app dies before the next launch reaches
   stable (boot probation, as mob_deliver's Watchdog does). The agent gets the
   crash report as a message so it can fix and retry.

### Runtime containment (Dyn code is always called through the Core)
- Tools and hooks run in a spawned process per call: timeout (tool default
  30 s), `max_heap_size`, exits trapped and turned into a tool error result
  (the loop continues, exactly like pi's `isError: true`).
- Screens run under mob's router, which restarts a crashed screen and gives
  up to `on_no_live_screen`; Operator sets that to "show the rescue screen"
  instead of ending the app.
- A hook that errors is skipped for that turn and reported (pi's handler
  isolation); three failures disable it until the agent fixes it.

### Safe mode (the sacred escape hatch)
Entered when two launches in a row fail to reach stable, or by holding a
volume key / a long-press during launch. Boots the Core only (no Dyn
modules), shows the rescue screen: generations list with diffs, revert,
crash log, and a chat with the agent using Core tools only, so it can still
repair the Dyn layer. Nothing the agent writes can remove or cover it.

### What one node can't catch (and the answer)
A whole-BEAM death (a NIF segfault, the OS killing the app for memory) kills
the Core too. Boot probation + safe mode recover on the next launch, so the
worst case is "the app closes once, then comes back on the last good
generation." `max_heap_size` doesn't cover off-heap binaries; the Keeper
also watches total memory and stops the offending process. If field data
shows whole-BEAM deaths matter, Android can add sloppy_joe's phase-2
lifeline (a second BEAM in a `:lifeline` service process); iOS can't.

## 3. The agent loop (ported from pi-agent-core)

A GenServer per session (`Operator.Core.Loop`), events broadcast to the chat
screen. Shape from `pi-agent-core/src/agent-loop.ts`:

- **Events**: `agent_start`, per turn `turn_start` → `message_start` /
  `message_update` (streamed text/thinking deltas) / `message_end` →
  `tool_execution_start/update/end` → `turn_end` (always emitted, even on
  error), `agent_end`.
- **Tool calls**: the model's calls in one reply execute **in parallel**
  (Tasks), results are appended **in the original call order**. A
  `before_tool_call` gate can allow, block (synthetic error result) or
  require approval (biometric for destructive or self-modifying tools).
- **Steering** (the thing that makes omp feel alive): messages Kevin sends
  while the agent works are queued and injected at the next step boundary
  (after the current tool batch), not as a new turn; `follow_up` messages
  run after the agent would otherwise stop; Stop aborts the in-flight model
  call and not-yet-started tools, lets started ones finish.
- **Guards**: max iterations per run, per-run token/cost budget (the $ cap),
  retry with backoff on transient provider errors, explicit `max_tokens`
  always (req_llm's default of 64k got a 402 on a small balance).
- **Output budget**: tool results over a byte budget are truncated in the
  middle (head + tail kept) and the full output spilled to an artifact file
  the agent can read on demand (`artifact://<id>`).
- **Compaction**: when the context nears the model's window, summarize older
  turns into a `compaction_summary` entry (keeping prior summaries and the
  recent tail), and retry once on a context-overflow error.

### Session = plain text
Append-only JSONL per session, resumed by replaying it. Being plain text
keeps the door open to handing a session to another host.

### Session format (changed in step 1: omp/pi's own, not a trimmed copy)
Sessions must move between omp on a computer and Operator on the phone, so
the file **is** pi's format; the types live in
`pi-coding-agent/src/session/session-entries.ts` (`CURRENT_SESSION_VERSION`
3) and `pi-ai`'s `AgentMessage` / `Usage`. Operator does not define its own:

- Line 1: `{"type":"session","version":3,"id":<UUIDv7>,"timestamp","cwd","title","titleSource"}`;
  file name `<ISO time>_<id>.jsonl` under `<data dir>/sessions`, as omp names them.
- Every entry: `type`, `id` (8 hex), `parentId` (a tree; Operator appends a
  linear chain, the last entry is the leaf), ISO `timestamp`.
- Written by Operator: `model_change` (`"openrouter/<model>"`, first and on
  switches), `message` with pi's user / assistant (`text`/`thinking`/
  `toolCall` content, `api`/`provider`/`model`, `usage`, `stopReason`,
  `errorMessage`) / `toolResult` shapes, and `custom_message`
  (`operator.notice` / `operator.error` / `operator.aside`).
- Read: every entry is kept (omp's `custom`, `compaction`, `title_change`,
  `credential_pin`, …; Operator only appends). The model context walks the
  leaf's branch and uses `message` and `custom_message` entries, like pi's
  `buildSessionContext`; compaction entries are ignored until step 3.
  `custom_message` goes to the model as a user message (pi sends it as a
  developer message, which OpenRouter's chat API has no slot for).
- Planned entries from §2 (`generation`) will be pi `custom` entries, which
  omp carries but ignores.

The transcript renders the GitHub-flavoured Markdown subset omp's terminal
renders (`pi-tui/src/components/markdown.ts`), so a session reads the same in
both; colour comes from role and construct only (`Operator.Core.Term`).

## 4. Tools in v1

Core: `read`, `write`/`edit` (hashline anchors, on the agent's own Dyn
sources and a notes area), `search`, `compile_and_test` (steps 2–4),
`propose_generation` (step 5), `revert`, `generations`, `todo`. Phone
(Dyn-replaceable wrappers around plugins): camera photo, photo picker,
location, notifications, clipboard/share, `http_get` (with the CA certs).
Each with name, description, schema (Jido.Action), streaming progress, and a
`selftest/0`.

## 5. Model and cost
OpenRouter via req_llm (key from the PKCE sign-in, moving to the platform
secure store). Default model: a cheap Claude/GPT tier for chat, a stronger
one for self-modification work, both user-selectable; per-day cost cap
enforced by the loop from OpenRouter's reported usage, with an optional hard
limit on the OpenRouter key itself.

## 6. Known constraints
- Android 15 cuts a backgrounded app's network after ~60 s: a run pauses
  when Kevin leaves the app, and resumes on return (checkpoint per step).
  A foreground service is a later option.
- iOS not yet tried for Operator (simulators were broken host-wide; the
  iPhone needs a cable deploy).
- jido_ai's ReAct runner is not used (it breaks on OpenRouter's second
  turn); Jido is used for actions/tool schemas.

## 7. Build order
1. Core loop + JSONL session + streaming chat screen + steering/stop, with
   one Core tool; host tests, then the Moto G.
2. Generations, registry, versioned compile, selftests, Keeper, boot
   probation, safe mode + rescue screen; the agent creates its first Dyn
   screen end to end with biometric approval.
3. Phone tools, output budget + artifacts, compaction, cost cap.
4. Secure-store key, iOS build, polish.
