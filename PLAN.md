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

## Terminal rendering

**Order (Kevin, 2026-10-03):**
1. **Now (fallback renderer):** the transcript is a mob `:list` (Compose
   `LazyColumn`, virtualized) of `:wrap` rows (`FlowRow`) of styled `:text`
   pieces from our own Markdown parser (`Operator.Core.Term`), monospace,
   stuck to the bottom while streaming. Copying: long-press copies a whole
   message (`Mob.Clipboard.put/2`), tap-to-copy on code blocks, "Copy last
   reply".
2. **Next (real renderer): a native Markdown view per reply**, a mob
   `native_view` component (`markdown`, props: the reply's Markdown text and
   the theme) in the same `:list`. Streaming updates the last reply's text.
   - Android: **Markwon** (commonmark-java → native Spannables in a
     `TextView`, no HTML step; `setTextIsSelectable(true)` for
     drag-to-select; table and code plugins).
   - iOS: **Textual** (successor of MarkdownUI, same author; MarkdownUI is
     in maintenance mode) or Apple's Markdown parser into an
     `AttributedString` shown in a read-only selectable `UITextView`;
     choose by which gives partial selection and tables.
   This gives true inline styling and selection natively, so Operator no
   longer depends on **MOB-374** (still useful for other apps). Our parser
   stays as the fallback and for anywhere a native view isn't available.
3. Rust is available if we ever want one parser for both platforms: mob
   builds Rustler NIFs statically (`mix mob.add_nif <name> --type
   rustler`), so MDEx/comrak could run on device; not needed with step 2.

**Fallback: a self-hosted WebView** (`Mob.UI.webview/1`, local HTML/JS only,
talking to the app through mob's `postMessage` bridge). It already solves
selection, inline styling, scrollbars and even ANSI (xterm.js), but Kevin
would rather not, so it's the fallback, used only if one of these holds:
- the native transcript can't keep up with streaming on the Moto G (dropped
  frames or input lag a throttle can't fix);
- MOB-374 turns out impractical on one platform (e.g. iOS range selection);
- Operator needs real terminal emulation (running programs that emit ANSI).
If it comes to that, only the transcript moves into the WebView; the input
field, approvals and the rest of the app stay native.

## Background processing (Android is the main target)

Operator isn't going to an app store yet, so **Android comes first** and iOS
gets the best it can without store review.

- **Android: keep running while backgrounded.** Done (code; device checks
  below): `mob_background` 0.1.2 is activated (signature verified against
  the mob release key) and `Operator.Core.KeepAlive` turns its `dataSync`
  foreground service on at a run's start and off 20 s after the last run
  ended (no flapping between back-to-back runs; a loop that dies or is
  replaced by a new session counts as ended). The service class is copied
  into `android/.../io/mob/background/` and declared in the manifest, as
  the plugin requires. This should also lift the problem the spike
  measured: Android 15 cut a backgrounded app's network ~60 s after it
  left the screen.
  - `mob_background` declares a `dataSync` foreground service. Since
    Android 15, `dataSync` may run at most 6 hours per 24 h (0.1.2 handles
    `onTimeout` by stopping). Fine for agent runs; if it ever bites, switch
    the plugin to `specialUse` (no time limit; its justification only
    matters for Play Store review).
  - Not yet: the notification showing what the agent is doing ("Running:
    editing Notes screen · 3 tools") with Stop. 0.1.2's text is fixed
    ("Running in background") and it has no action; it needs a plugin
    release (an update-text NIF, a Stop action that reaches the BEAM).
  - Android 13+ shows the notification only once POST_NOTIFICATIONS is
    granted (declared in the manifest; the app doesn't request it yet:
    `Mob.Permissions.request(socket, :notifications)` from the chat screen).
    The service runs either way.
- **iOS: tell people to keep the app in front**, or keep an audio session
  alive. `mob_background` already does the latter with a silent
  `AVAudioEngine` session; acceptable here because there's no store review.
  Same code path as Android; untested.
- **The agent speaks.** Done (code; device checks below):
  `Operator.Core.Voice` reads out a finished run (first sentence of the
  final reply, ≤ 200 chars, Markdown stripped), stopped, error (its first
  sentence) and the step limit. Setting `Operator.Core.Settings.voice/0`
  (`:off | :important | :everything`, default `:important`;
  `put_voice/1`), in `settings.json` in the data dir; `:everything` also
  reads each assistant reply. While an utterance plays (estimated from its
  length; the platforms don't report the end) a reply is skipped and a
  run-end line interrupts it. Speech from a non-screen process: `Mob.Speech`
  ignores its socket and calls `:mob_nif.tts_speak/2` / `tts_stop/0`, which
  work from any process; Android's needs the Activity to exist (it does
  while backgrounded, unless the system destroyed it).
  - Not yet: the ChatScreen toggle (after the Markdown view lands), "needs
    approval" (no approval event in the loop yet).
  - iOS: `Mob.Speech` sets no audio session category; in the background it
    plays under the keep-alive's (Playback, MixWithOthers), which stays on
    20 s after a run so the run-end line can finish. To verify.
- **Coming back to the app** shows what happened while away (the transcript
  is the record), and a notification is posted when a backgrounded run
  finishes or needs approval (biometric approval needs the app in front).
  Not yet (needs `mob_notify`).

Device checks (Moto G, `mix mob.deploy --native --android`, which also
regenerates the tracked plugin bootstrap / bridge Kotlin; commit those):

1. A run that outlasts 60 s with the app backgrounded (screen off too):
   tool calls and model calls keep going, the network stays up, the run
   finishes; the foreground-service notification appears at the start and
   goes away ~20 s after the end.
2. Notification text: "Running in background" (fixed in 0.1.2), visible
   only with POST_NOTIFICATIONS granted.
3. Speech audible: run finished (foreground and backgrounded), Stop, an
   error (e.g. a bad model), `put_voice(:everything)` / `:off` over rpc.
4. iOS: not tested.

## Transcript rendering contract (phone ⇄ omp)

A session moves between the phone and omp, so what the model writes must
render well in both. The contract is **omp's own Markdown subset**
(`pi-tui/src/components/markdown.ts`): headings, paragraphs, bold, italic,
strikethrough, inline code, fenced code blocks with a language, links,
lists, tables, blockquotes, rules, a few HTML tags, and `$…$` math. No
phone-only markup (no custom colour tags).
- **Phone renderer** (`Operator.Core.Term`) implements that subset; anything
  it can't render degrades to readable plain text, never raw syntax.
- **Colour** comes from role (user / assistant / tool / error / notice) and
  construct (code, headings, links) in the theme, never from the model text.
- **Tool calls and results** render from the structured session entries, as
  omp's tool renderers do, not from the model's prose.
- Tested against a real (redacted) omp transcript: no raw markup survives.

**Copying.** Fields meant to be copied are **fenced code blocks**: the
system prompt tells the model to put commands, values, URLs, IDs and
snippets in them; the phone shows a Copy button on each, and in omp they're
ordinary code blocks. Anything else can still be copied: long-press copies a
whole message, "Copy last reply" sits by the input, and drag-to-select for
any text arrives with MOB-374.

## Build order

1. **Core loop** (in progress): pi's turn loop on req_llm (OpenRouter),
   steering/follow-up/stop, parallel tools with ordered results, omp/pi-format
   JSONL sessions, terminal-style chat screen (own parser, streaming, stick
   to bottom, copy). Verify on the Moto G.
2. **Native Markdown view per reply** (Markwon on Android first) and
   **background runs on Android** (`mob_background` during a run, progress
   notification, network verified past 60 s) plus **spoken updates**
   (`Mob.Speech`).
3. **Self-modification**: generations with versioned module names, static
   check, selftests, biometric approval, probation, automatic revert, safe
   mode + rescue screen; agent-editable terminal theme as the first Dyn
   artifact.
4. **Phone tools, context management**: camera/photos/location/notifications/
   http; output budget + artifacts; compaction; cost cap.
5. **Session transfer omp ⇄ phone** (this document's compatibility section),
   starting with export/import files, then Muster as the relay.
6. Secure-store key; iOS build (Textual vs `UITextView`, audio-session
   background).
