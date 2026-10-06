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
2. **Models and providers.** The phone signs in to the same subscriptions
   omp does (Anthropic, OpenAI Codex), so a session's `anthropic/…` or
   `openai-codex/…` model continues as is when that provider is signed in;
   anything else continues on the default model. Provider-specific fields
   (`responseId`, thinking signatures, cache metadata) are kept but not
   replayed to a different provider.
3. **Paths and environment.** `cwd` and file paths in the history refer to the
   original host; the arrival notice says so.
4. **Size.** omp sessions can be large: transfer the latest branch only, or a
   compacted session (summary + recent tail), with artifacts referenced, not
   inlined, unless requested.
5. **Secrets.** Never transfer credentials; omp entries like `credentialId`
   and `credential_pin` are dropped on export.

Transport (decided, Kevin 2026-10-03): **QR codes, no server.** Work moves
to the phone as omp's own `/handoff` document, not as the transcript (which
assumes omp's tools: a shell, the Mac's files). `mix operator.handoff`
takes the latest handoff from the omp session and shows it as
`operator://handoff?…` QR codes (as many as it needs, scanned in any order,
with any QR app); the phone starts a new session that opens with it. Whole
session files over adb (`scripts/session.sh`) stay for debugging only.

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

   **Status (2a, Android, 2026-10-03): built, host-tested, APK compiles;
   not yet verified on the Moto G.** `Operator.Core.MarkdownView` (Elixir
   component) + `OperatorMarkdown.kt` (Markwon 4.6.2: core, tables,
   strikethrough, linkify, html; JetBrains Mono real faces for bold /
   italic / bold-italic; registered in `MainActivity`). Each prose stretch
   of a reply is one native view; fenced code blocks and `$$` math stay
   Term rows so Copy-per-block survives; the streaming reply's views grow
   in place (stable ids). The theme's `renderer: :native | :term | :auto`
   picks it (`:auto` = native on the phone); menu › renderer toggles it
   for the running app (not persisted). At most 200
   native views are in the window (mob has 256 component slots; a view
   without one renders nothing).

   **Status (2b, iOS, 2026-10-04): built and verified on the iOS 26.5
   simulator.** `ios/OperatorMarkdown.swift`: Foundation's Markdown parser
   (`AttributedString(markdown:)`, full syntax: GFM tables, strikethrough,
   autolinks) walked into an attributed string in a read-only selectable
   TextKit 1 `UITextView` (TextKit 2 under-measured long replies). Textual
   was not used: it's a SwiftPM package and mob's iOS build is one
   `swiftc` call over source files (no package resolution); the
   `UITextView` gives partial selection natively. Tables are drawn
   as box-drawing text in the monospace face, columns shrunk to the view's
   width and cells wrapped, a rule under every row (Markwon's grid); they
   select and copy as text. Links go to the BEAM (`open_link`) on tap and
   through a custom long-press menu, never opened by UIKit. Verified:
   streaming growth, partial drag-selection + Copy, headings, lists,
   quotes, rules, inline HTML, wide tables, link routing (a `javascript:`
   link refused).
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

**Verified 2026-10-03** (Android 15 emulator, `scripts/bgnet.sh`): without
the foreground service, Android freezes the backgrounded app outright (no
dist, no network); with it, an HTTPS request 75 s after backgrounding with
the screen off returned 200 in under a second. The Moto G 2021 runs
Android 11, which has no such restriction.

## Speech to text (quick entry)

Talking is faster than typing on a phone, and the agent already talks back
(`Mob.Speech`), so input works by voice too.
- **Hold to talk** (Kevin, 2026-10-03): hold the mic next to Send while
  speaking; on release the transcript goes into the composer to edit, and
  is never sent by itself. A press under 300 ms only shows a hint.
- **Built on mob, not app code:** the mic is a plain box with mob's
  `on_press_in` / `on_press_out` (mob 0.9.12, MOB-380); recognition is
  `mob_speech` with the `mob_whisper` engine (offline whisper.cpp,
  `base.en`, 60 MB model downloaded once and prefetched when the chat
  opens; MOB-381). Text arrives ~1.5–2.5 s after release on the Moto G 2021.
- **Why not Android's `SpeechRecognizer`:** on the Moto G 2021 the Google
  app's service returned empty results (no language pack; Gboard voice
  typing fails too) and took 10–20 s to report back after stop.
- `mob_speech` and `mob_whisper` come from git tags (0.1.0) until their
  repos have a `HEX_API_KEY` (Kevin).
- **iOS:** `mob_whisper` builds for iOS (AudioQueue capture) but hasn't
  run on an iPhone.

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
ordinary code blocks. Anything else can still be copied: "Copy last reply"
sits by the input; with the native renderer any text is drag-selectable
(long-press, handles, Copy), and on Term rows long-press copies a whole
message.

## Front and back: the app you modify (Kevin, 2026-10-03)

A terminal alone has few uses on a phone; what's fun is **changing the app
itself**. So Operator becomes what Sloppy Joe is (`~/code/sloppy_joe`): a
**front** (the UI side, whatever the user builds) and a **back** (Operator's
terminal, the agent that builds it). The agent runs on the phone, so unlike
Sloppy Joe there's no Mac-side Control Node or MCP in the loop.

- **The toggle.** On the front, Operator's logo (the rotary dial,
  `assets/icon/`) is a button in the upper-left corner; tapping it switches
  to the terminal. On the terminal it is the `[frontend]` command that starts
  every top bar (Kevin, 2026-10-05: no logo on the terminal side), next to
  `[menu]`. It's drawn by the shell,
  outside any user screen, so a broken front screen can never hide it.
  Sloppy Joe's equivalent is the gear in `ShellScreen` (`view: :app |
  :control`).
  **It can't be removed** (Kevin, 2026-10-03): no change can hide it, cover
  it, move it off screen or make it untappable, so the way back to the
  terminal always exists. What a user *can* change is its **symbol**: a
  different glyph or image instead of the dial, kept as a Dyn setting the
  shell draws, not front code drawing its own button.
- **A shell hosts the front, and draws nothing else.** A Core screen owns
  the toggle and mounts the current front screen full-bleed under
  try/rescue: a screen that raises shows its error and stacktrace, and the
  shell and terminal stay up. The last open front screen is remembered
  across launches. Repeated crashes revert through the Dyn Keeper's
  probation and automatic revert, which already exist (Sloppy Joe's
  `CanvasKeeper` plays that part there).
- **Nothing in the front is hardcoded** (Kevin, 2026-10-03). The logo
  toggle is the only thing Operator draws over it: no home button, menu,
  tab bar, consent card or blank-state card like Sloppy Joe's. Navigation
  between front screens is whatever the user builds; if they build
  something with no way out, the agent can open any front screen for them
  from the terminal (a tool), or rebuild the navigation.
- **The front can't nuke the terminal** (Kevin, 2026-10-03). Whatever a
  front change does, the worst outcome is a blank front; the logo toggle
  and the terminal always work, so the agent can always fix it. For now
  that's structural only: the terminal, the toggle, approval and rescue
  are Core and never call front code, and the existing static check keeps
  Dyn modules out of Core internals.
- **Scope: personal use** (Kevin, 2026-10-03). Operator is Kevin's own
  tool; if a change ever leaves it unusable, reinstalling is the fallback.
  So no extra hardening now (per-screen heap/CPU limits, validating the
  toggle's symbol or the terminal theme for visibility, sandboxing plugin
  calls). Revisit if it's ever released for others.
- **Front screens are Dyn artifacts.** The agent writes them with its
  `dyn_*` tools as modules of a generation; they go through the static
  check, selftests, approval and probation like everything else in Dyn, and
  any generation can be reverted. **Every front change needs the screen
  lock**, one approval per proposal, the same as any other self-change
  (Kevin, 2026-10-03). Sloppy Joe keeps screen sources in SQLite
  (`SloppyJoe.Store`) and compiles them on the phone (`SloppyJoe.Screens`);
  Operator's generations already do both. The Rescue screen still works
  when the front is broken.
- **Default front: every Mishka Chelekom widget.** A fresh install opens on
  the widget gallery that `mix mob.new` generates (not `--blank`):
  `Showcase.GalleryScreen` plus one screen per component (60 component
  screens over `mob_mishka`'s composites; template in
  `mob_new/priv/templates/mob.new/lib/app_name/showcase/`). They're shipped
  as the seed generation's front screens, so they are themselves editable
  ("make the slider purple", "add a page that uses the chip"), the way
  Sloppy Joe seeds `priv/default_screens` into its store so the bundled
  demos stay modifiable. Restoring the defaults = reverting to the seed.
- **Every capability Sloppy Joe has.** Operator carries all of Sloppy Joe's
  plugins and permissions, so whatever a user asks for can be built without
  a native rebuild:
  - Plugins to add: `mob_mishka`, `mob_themes`, `mob_bluetooth`,
    `mob_screencast`, `mob_video`, `mob_touch`, `mob_wake`, and
    `mob_biometric` for front screens (approval of self-changes stays on
    `OperatorApproval.kt` / `ios/OperatorApproval.swift`). Already in: camera, location, notify, photos,
    scanner, background, deliver, speech/whisper. Added 2026-10-04 (every
    other first-party plugin on Hex): `mob_sms`, `mob_vision`, `mob_nfc`,
    `mob_midi`, `mob_audio_capture` (Android only), `mob_scene3d`,
    `mob_nx_eigen`, `mob_rapier` (static NIF `:lab_physics`) and `mob_ash`;
    left out: `mob_push` (a server-side sender) and the unpublished ones.
  - Android permissions (Sloppy Joe's manifest): CAMERA (+ camera and
    autofocus features, not required), ACCESS_FINE/COARSE_LOCATION,
    READ_MEDIA_IMAGES / READ_MEDIA_VIDEO (+ READ_EXTERNAL_STORAGE up to
    API 32), BLUETOOTH_SCAN / CONNECT / ADVERTISE (+ BLUETOOTH and
    BLUETOOTH_ADMIN up to API 30, bluetooth feature not required), plus
    what Operator already has (RECORD_AUDIO, POST_NOTIFICATIONS, VIBRATE,
    USB host, boot, exact alarms, biometric) and whatever the screencast,
    video, touch and wake plugins declare. Check the **built** manifest
    (plugins inject entries at build time), not only the source file.
  - iOS Info.plist: camera, microphone, photo library, location when in
    use, Bluetooth and Face ID usage strings, plus the plugins' own.
  - Each permission is still requested at first use, by the screen that
    needs it (`Mob.Permissions.request/2`), never all at launch.
  - Store distribution: not now. Play would want declarations for
    Bluetooth, background location, media projection and the foreground
    service type; that's for when we bundle it for a store.
- **The agent knows the front.** The system prompt gets a front guide (how
  a front screen is written, mob's components, the Mishka widgets, the
  capability plugins and their permissions), like Sloppy Joe's
  `priv/screen_guide.md`, and tools to list, open and screenshot front
  screens so it can see what it built, and to switch the front to any
  screen when the user asks.

## Build order

1. **Core loop** (done, device-verified): pi's turn loop on req_llm (first OpenRouter, now the Anthropic/OpenAI subscription logins, step 7),
   steering/follow-up/stop, parallel tools with ordered results, omp/pi-format
   JSONL sessions, terminal-style chat screen (own parser, streaming, stick
   to bottom, copy). Verify on the Moto G.
2. **Native Markdown view per reply** (Markwon on Android first) and
   **background runs on Android** (`mob_background` during a run, progress
   notification, network verified past 60 s) plus **spoken updates**
   (`Mob.Speech`). Done and device-verified, including the notification
   permission ask (first send) and the `[voice:…]` setting.
2b. **Speech to text** (section above): hold-to-talk mic, transcript into
   the composer, unsent. Done: offline Whisper via `mob_speech` +
   `mob_whisper`, mob's press events; verified on the Moto G 2021 by hand
   (Kevin) and with `Mob.Test.press_down_xy` / `press_up_xy` while the Mac
   spoke a sentence.
3. **Self-modification**: generations with versioned module names, static
   check, selftests, screen-lock approval, probation, automatic revert, safe
   mode + rescue screen; agent-editable terminal theme as the first Dyn
   artifact. Built: engine, review fixes, proposal card (fingerprint approve
   / deny), the agent's `dyn_*` tools, Dyn guide in the system prompt.
   Verified: whole cycle on the Android 15 emulator with a simulated
   fingerprint (propose -> card -> fingerprint -> probation -> relaunch ->
   proven, the Dyn screen runs); on the Moto: boot, card, deny/discard; the
   Moto has no fingerprint enrolled. Approval now takes the screen lock
   (fingerprint, face, PIN, pattern or password: the app's own
   `OperatorApproval.kt` prompt, chat card and rescue revert; mob_biometric
   dropped); verified on the Android 15 emulator with a PIN. iOS:
   `ios/OperatorApproval.swift` (LAContext `.deviceOwnerAuthentication`:
   Face ID / Touch ID, falling back to the passcode), verified on the iOS
   26.5 simulator (Face ID match approves; non-match then Cancel → "not
   activated"; passcode fallback approves; rescue revert approves; a
   superseding proposal closes the open prompt and its pass approves
   nothing). Each prompt is bound to its proposal: the chip carries
   `request`, the native views tag every answer with it, and
   `Operator.Core.ApproveButton` drops answers for any other request. The theme artifact is done (`Operator.Dyn.Theme`
   with `overrides/0`, applied by `Operator.Core.DynTheme`; a warm theme
   proposed, fingerprint-approved and drawn on the emulator), and automatic
   revert was seen on the emulator (a Dyn tool crashing 3 times through
   ToolRunner: generation 3 reverted to 2, the tool gone). Not yet: the
   agent writing a change itself (needs a provider login). Phone tools
   become Dyn-replaceable by shipping them in a seed generation (a Core
   tool's name can't be taken by a Dyn tool).
4. **Phone tools, context management**: camera/photos/location/notifications/
   http; output budget + artifacts; compaction; cost cap. Done and
   device-verified: output budget + `read_artifact`, compaction (pi's soft
   method, pi-shaped entries), daily cost cap ($1.00 default), `location`,
   `notify`, `camera_photo` and `pick_photos` (through the chat screen, which
   asks for permissions; cancel paths verified, no photo taken at night),
   `clipboard`; `http_get` unit-tested.
5. **Session transfer omp ⇄ phone** (this document's compatibility section).
   Moving work to the phone is the handoff: `/handoff` in omp, then `mix
   operator.handoff` shows it as `operator://` QR codes; scanned with the
   camera, any QR app or Diagnostics → Scan QR, in any order, they open
   Operator, and the last one starts a new session that opens with the
   handoff (`Operator.Handoff`, `Operator.Links`; links arrive as mob's
   `{:link, ...}` since mob 0.9.11, MOB-379; `url_schemes` in mob.exs declares
   the scheme). Built and
   host-tested; not yet tried on a device. Files over adb
   (`scripts/session.sh pull|push`, verified both ways) stay for debugging
   only; the Muster relay is dropped.
6. Secure-store key; iOS build (Textual vs `UITextView`, audio-session
   background). Secure-store key done on Android (EncryptedSharedPreferences,
   migrated and verified on the Moto); iOS not started.
7. **Provider logins** (Kevin, 2026-10-03: OpenRouter removed). Signing in
   to Claude (Pro/Max) or ChatGPT/Codex runs omp's
   PKCE flows on the phone (browser -> localhost listener, or paste
   `code#state`); credentials pi-shaped in the secure store, refreshed by
   `Operator.Auth`. From the Mac: `mix operator.login anthropic|openai`
   prints an encrypted `operator://login` QR plus six words; scanning it
   (camera, any QR app, or menu › accounts › scan a login QR) opens the phone at the
   words. Built and reviewed (reviewer subagent: SHIP after fixes);
   the Claude sign-in verified on the Moto (Kevin signed in; replies stream
   from claude-haiku-4-5 on his subscription); the ChatGPT one and the
   Mac QR transfer (`mix operator.login`, scanned on the phone) verified on
   the Moto too.
8. **OTA updates of the Core** (Kevin, 2026-10-03: from the Mac, home
   network only, nothing through Muster). mob_deliver 0.3.1 on the phone,
   mob_deliver_server 0.2.0 + Bandit on the Mac (dev-only): `mix
   operator.deliver.key`, `.serve` (port 8040, store
   `~/.local/share/operator/deliver`), `.qr`, `mix operator.publish`
   (AGENTS.md "How to update the phone"; DESIGN.md §1 "The Core's release
   path"). Publishes Operator's own modules (not the entry module, the
   build config, NIF stubs or Mix tasks); the endpoint comes from an
   `operator://deliver?endpoint=…&key=…` QR (key fingerprint must match the
   build's), confirmed on screen and kept in settings; Diagnostics shows the server, the code
   running, the last check and "Check for updates now". The Keeper's stable
   launch also ends an update's probation, a Core change rebuilds and
   selftests the Dyn generation, and a launch that failed on a rolled-back
   Core update isn't counted against Dyn. Built, host-tested (publish ->
   serve -> mob_deliver's client; on the host also install -> next launch
   loads it -> no stable launch -> rolled back). Device checks 1-3 done on
   the Moto G 2021 (041305b, f627e2a, 98b5894; the confirm-tap change in
   them was host-tested only); 4 not done:
   1. Key, native deploy, serve, scan the QR with the camera: the scanner
      asks "Get Operator's code updates from …?"; "Use this server", then
      "Update server set …: close Operator and open it again"; after relaunching,
      Diagnostics shows the server and a last check ("nothing published
      yet" before the first publish).
   2. A visible Core change, `mix operator.publish`, Diagnostics → Check
      for updates now: "update installed"; after a relaunch the change
      shows, Diagnostics says "Running: update …", logcat has `[dyn]
      rebuilding generation …` if a generation exists; one more stable
      relaunch proves it. Note the boot line before and after (mob_deliver
      loads every delivered module at launch).
   3. A crashing update (e.g. `System.halt(1)` 5 s after the first frame in
      `Operator.App.on_start`): the launch dies; the next one logs
      `mob_deliver: manifest … never reached first idle; rolling back` and
      `[dyn] the last launch failed on a Core update that was rolled back`,
      runs the old code, keeps the Dyn generation, and Diagnostics shows
      the rollback notice; Check now says the update was rolled back
      before. Publishing the fix installs again.
   4. A QR from another key (or a build without one) is refused and
      nothing changes.
9. **Front and back** (section above). In order:
   1. Capabilities: add the missing plugins and Sloppy Joe's permissions
      (Android manifest, iOS Info.plist); native deploy; check the built
      manifest and that each plugin starts.
   2. Shell screen with the logo toggle (upper left) between the front and
      the terminal, and nothing else drawn over the front; front screens
      mounted under try/rescue showing the error; last open front screen
      remembered.
   3. Default front: the generated Mishka gallery and component screens as
      the seed generation's front, so they're editable and revertable.
   4. Agent side: front guide in the system prompt; tools to list, open
      (switch the front to) and screenshot front screens; a front change is
      a Dyn proposal approved with the screen lock.
   5. Device check on the Moto: toggle both ways, a front screen that
      raises shows the error box and the logo still works, the agent
      changes a Mishka screen ("make the slider purple") and it's approved,
      shown, survives a relaunch, and reverts.

   **Status (2026-10-03).** 9.1 done (9597a8e, fc857d6; Codex SHIP): every
   Sloppy Joe plugin from Hex and activated (mishka, themes as style,
   biometric, bluetooth, screencast, video, touch, wake), built-APK manifest
   = Sloppy Joe's permissions/features/services (only SJ's legacy in-app
   scanner/FCM class names differ), iOS usage strings added; permissions
   asked at first use only. Proven on the Moto G 2021: boots to chat, all
   plugin apps started and NIFs load, no crash; dictation, location, notify
   and camera tools still work. Open: FCM push (mob_notify/mob_wake) needs a
   Firebase app for com.genericjam.operator (Kevin, console); iOS not built.

   9.2-9.4 done (8f2c930 check, bdc9761 front; FrontReview subagent SHIP).
   A Core update rebuilds the current generation in the background after
   boot ("Preparing the front…" meanwhile); unchanged files are rebuilt from
   the parent's BEAM with renamed atoms instead of recompiled.

   9.5 on the Moto, up to the approval: the seed installed as generation 3
   (67 files, 39 s under launch load); after a BEAM deploy the front showed
   "Preparing…" and was back within about 45 s; gallery shown; toggle
   front → terminal → front from the gallery and from Hue Slider; Android
   back on the front goes to the terminal; a raising front screen (an
   injected render raise, removed by relaunching) shows its error and
   stacktrace and the toggle still works both ways; `front_screenshot` from
   the chat returned the gallery and the model described it; Light,
   Material and Dark front themes switch. "make the slider purple on the
   Slider screen" in a new session: proposal (generation 4, a
   `color={0xFF7C3AED}` on the Volume slider) 42 s after Send, of which the
   compile was 22.4 s (1 file compiled, 67 reused; selftests 58 ms). The
   reuse path is slower than the 7 s the RPC measurement suggested. Still
   to do: Kevin approves it with the screen lock, then check it's shown,
   survives a relaunch, and reverts.

   Deferred (personal-use scope, Kevin 2026-10-03): no max_heap_size on the
   front Host (an out-of-memory front takes the app down; safe mode is the
   backstop); a cold-start `operator://` link can race the front push;
   `Mob.Wake`/Erlang atoms as values aren't checked (same gap as
   `:timer.apply_after`); a Keeper restart during a background rebuild
   loses it; front_screenshot's cleanup can pop a shell the user pushed.
   Not tried on the device: the gallery replacing the old stack when the
   seed installs (host-tested; this phone was seeded before that change).
   The Light theme draws the gallery's cards white on white.
10. **Agent onboarding** (Kevin, 2026-10-04). The agent on the phone has no
   mob docs otherwise. `mix operator.docs` writes `priv/docs/` from the
   locked deps (mob's app guides from that version's HexDocs, the app parts
   of mob's AGENTS.md, the Mishka widgets with their gallery screens, each
   activated plugin's README; commit the output), embedded by
   `Operator.Core.Docs`; Core tools `read_guide` (section, lines, budget)
   and `read_doc` (`Code.fetch_docs`: dev deploys keep Docs chunks, checked
   on the Moto; an OTA update strips Operator's own). System prompt: "This
   environment", "Building with mob" (read the guide / `read_doc` before an
   unfamiliar API) and the guide index. Done; on the Moto G 2021 Haiku read
   the guides and docs and proposed a location screen with Mishka tabs from
   the gallery (G11 pending: Kevin approves). Haiku often hits the 12-call
   limit on a new screen.
11. **Settings menu** (Kevin, 2026-10-05, before the first public APK). The
   terminal's top bar is `[frontend]` (to the front, what the dial does
   there) and `[menu]`, then the status line; no logo on the terminal side.
   `[menu]` opens `Operator.MenuScreen`, a full-screen page in the
   terminal's look (`Operator.TermUI`): accounts (sign in with the browser,
   paste `code#state`, sign out after a confirm, scan a login QR), model
   (the picker plus a custom spec), new session, resume a saved session,
   renderer (`md:native` / `md:term`) and diagnostics
   (`Operator.DiagnosticsScreen`, the old Home screen). The chat's
   `/login`, `/logout` and `/models` are gone: the composer only talks to
   the agent. Signed out, the chat is still the root and says where to
   sign in.
12. **Attachments** (Kevin, 2026-10-05, before the first public APK).
   `[attach]` beside the mic opens `[photo library] [take photo] [file]`;
   picks wait above the composer as `[x] name size` and go with the next
   message (which may be files only). `Operator.Core.Attachments` is the one
   implementation behind `[attach]` and the `pick_photos`, `photos_recent`,
   `camera_photo`, `camera_snap` and `file_pick` tools: copies in the
   workspace's `inbox/` (snaps in `photos/`), pictures scaled with their
   EXIF, text inlined up to the output budget, PDFs as document parts.
   Messages carry pi's content parts (an `<attachment>` text block per file,
   then the image); a model without image input gets the path and
   metadata only.
13. **Usage** (Kevin, 2026-10-06; Moto-verified). `[menu]` › usage
   (`Operator.UsageScreen`) shows what each subscription has left: the
   5-hour and weekly windows (percent used, time to reset), the last 429
   and when it resets, then requests, tokens (in / out / cache) and cost
   for the session, today, all time and per model. The numbers come from
   every call's response headers (Claude `anthropic-ratelimit-unified-5h/7d-*`,
   Codex `x-codex-primary/secondary-*`, read from req_llm's stream
   metadata) and from the OAuth usage endpoints omp uses
   (`/api/oauth/usage`, `/backend-api/wham/usage`), asked when the page
   opens on numbers over 5 minutes old or on `[refresh]`; they live in
   `usage.json` (`Operator.Core.Usage`). The chat's status line shows the
   current model's provider as `5h 42% · wk 18%` (plus `429 3d 6h` while a
   limit holds). Counting starts with this version (old sessions aren't
   backfilled); cost is req_llm's and reads $0 for models it has no price for.
14. **The composer** (Kevin, 2026-10-06). Tapping the terminal's input
   slides a composer up over everything above the keyboard but a sliver:
   the status line and the transcript's last two lines stay on top, live.
   It holds a tall multi-line field (it scrolls), `[attach]` and its chips,
   the mic (dictation lands in the field), Send/Steer and Stop; `[hide]`
   closes it and keeps the draft, sending closes it too. Plain layout, not
   mob's `:sheet`: the field keeps its id and place in the tree from the
   bar to the composer, so the tap's focus and the keyboard carry over
   (one tap), and the sliver is the same transcript list, shrunk.
   Android's back still leaves the app from the composer (mob's router
   owns back at a stack's root).

## iOS parity (2026-10-04)

Builds: `mix mob.deploy --native --ios --device <udid>` for the iOS 27
simulator (57 s) and Kevin's iPhone SE 3rd gen, iOS 26.5.2 (77 s, signed
with the team's wildcard profile). Dist to the iPhone: its node is named
after its WiFi IP (`operator_ios@10.0.0.121`); `mix mob.connect` can't find
it on this Mac (MOB-384: the BEAM's `arp` output is empty), so connect by
hand with a driver node on the Mac's LAN IP. "Kevin" = waiting for his
finger on the iPhone (list sent 2026-10-04).

| Feature | Android | iOS simulator | iPhone SE | Notes / issue |
|---|---|---|---|---|
| Boot to the shell: front gallery + dial toggle, terminal | Moto, verified | verified (27.0) | verified: seed generation compiled and proven on device, toggle both ways | Dyn compiles and loads on the iPhone's no-JIT BEAM (`emu` flavor) |
| Secure store (Keychain) | verified | verified: put/get/delete, survives relaunch | verified: put/get/delete | sim needed simulated entitlements (`ios/simulator_entitlements.plist` linked into `__TEXT,__entitlements`); upstream MOB-314 (commented) |
| operator:// links | verified | warm: verified (deliver link → confirm screen); cold start: link not shown after launch | warm: verified (`devicectl … --payload-url`) | cold start is PLAN's deferred "cold link races the front push" |
| Provider logins (menu › accounts, QR transfer) | verified | not run (needs a sign-in) | Kevin | on iOS the localhost listener runs while Safari is in front only if the app isn't suspended (see Background); paste `code#state` is the fallback |
| Model calls streaming | verified | not run (needs a login) | Kevin (after login) | |
| Markdown rendering | see 2a | IosViews: verified (26.5 sim) | IosViews: rendered (proposal text) | `ios/OperatorMarkdown.swift` |
| Screen-lock approval, rescue revert | verified (emu) | IosViews: verified (Face ID, passcode) | Kevin (Touch ID on the G2 card) | `ios/OperatorApproval.swift`; native + Elixir must ship together (request binding) |
| Hold-to-talk dictation (Whisper) | verified | verified: "Please check the weather in Calgary tomorrow morning." exact, 0.5 s after release (Mac `say`) | Kevin (microphone permission), then the `say` check | mic enabled on iOS (f6147ff); `Mob.Test.press_down_xy` is unsupported on iOS, driven with `press_in/press_out` |
| Voice output (Mob.Speech) | verified | `tts_speak` :ok (not listened to) | not checked by ear | |
| location | verified | verified (simctl location) | Kevin (permission prompt pending; the call timed out at 40 s without it) | |
| notify | verified | verified: permission asked at first send, banner shown | scheduled :ok; Kevin (permission) | |
| clipboard, http_get | verified | verified | verified | |
| camera_photo, scanner | verified | n/a (no camera) | Kevin | |
| pick_photos | verified | verified (PHPicker, one photo) | Kevin | iOS items are path + type only: name and size now come from the file |
| front tools (screens, open, screenshot), read_guide, read_doc | verified | verified | verified | |
| Self-modification (Dyn compile + load) | verified | seed + proposals compile (IosViews: probation, rescue) | seed generation proven; G2 proposal compiled | auto-revert after crashes not rerun on iOS |
| Sloppy Joe plugins started | verified | all 17 apps started, NIFs answer | all 17 apps started, NIFs answer (wake, video, touch, screencast, camera, location, notify, whisper, background) | Bluetooth Classic is Android-only by design (BLE is cross-platform); push needs an explicit App ID with Push |
| mob_vision (OCR) | verified: "Operator OCR 42" from a generated PNG | verified: same text | not run | |
| mob_sms | composer intent opens Google Messages (this Moto has no SIM: "Could not start conversation") | `{:sms, :not_available}` (no Messages on the sim) | not run | |
| mob_nfc | `available?` false (Moto G Power 2021 has no NFC) | false (no NFC on the sim) | not run; device builds need the NFC entitlement in the provisioning profile | tag read/write/HCE need NFC hardware + tags |
| mob_midi | `list_devices` → `[]` | `[]` | not run | needs a USB/BLE MIDI device |
| mob_audio_capture | MediaProjection consent → capturing (`:silent`), stop → `:not_capturing` | `:unsupported_on_platform` (by design) | n/a | Android only |
| mob_scene3d | glb cube rendered in a throwaway screen | glb cube rendered | not run | iOS: `scripts/fetch_filament_ios.sh` first (ios/vendor, gitignored); device link wired in build_device.zig but not yet built |
| mob_rapier, mob_nx_eigen | ball drops and comes to rest; `Nx.dot` on `NxEigen.Backend` | same | not run | rapier is the `:lab_physics` static NIF |
| mob_ash | an Ash resource compiles on the phone in 675 ms, create/read on ETS, `MobAsh.ListScreen` shows it | apps start | not run | `config :ash, default_string_length_count` set |
| OTA updates (mob_deliver) | verified 1-3 | verified: deliver link → server set → publish → installed → runs after relaunch | link + server set; install not run | |
| Background (mob_background) | verified | n/a | verified: without the keep-alive the BEAM froze while Safari was in front (no tick for 100 s); with `MobBackground.keep_alive/0` it ticked every 5 s and HTTPS returned 200 at 30/60/90 s, dist stayed up | screen-locked case not tested; the run-start hook (`Operator.Core.KeepAlive`) needs a login to exercise |
