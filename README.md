<p align="center">
  <img src="assets/icon/operator_full.png" alt="Operator: a purple rotary dial with googly eyes" width="180">
</p>

# Operator

**A coding agent that lives in your phone and rewrites the app it runs in.**

Operator is an Android (and, in progress, iOS) app with two sides:

- **The back is a terminal.** A real coding agent, shaped like
  [omp](https://github.com/can1357/oh-my-pi)/pi: a session of JSONL entries,
  a model, tools called in parallel, steering and follow-ups while a run is
  going. It signs in to your own Claude Pro/Max or ChatGPT subscription on
  the phone, takes photos, reads your location, looks things up, and writes
  Elixir. Hold the mic to talk: speech is transcribed on the phone, offline.
- **The front is whatever you want.** It opens on a welcome screen with two
  ways on: the terminal and the **component library**, 75
  [Mishka Chelekom](https://mishka.tools) widget pages plus working widgets
  for the phone's capabilities (camera, microphone, location, sensors, QR,
  Bluetooth, NFC, MIDI, ...). Ask for a screen, a tracker, a game, a weird
  little tool, and the agent builds it on the phone; "use this" on a library
  page hands that widget to the agent. The rotary dial in the front's
  upper-left corner opens the terminal; there, `[frontend]` goes back and
  `[menu]` holds sign-in, model, sessions, usage (the subscription's 5-hour
  and weekly windows, tokens), the component library, a secure local cluster,
  and diagnostics. `[attach]` sends photos and files with a message.

Every change the agent makes to the app is compiled and self-tested on the
phone, then waits for **your screen lock** (fingerprint, face or PIN). New code
runs on probation and reverts itself if it keeps crashing. The terminal never
runs front code, so a broken front screen can't take it down.

It is built on [mob](https://github.com/GenericJam/mob), which runs Elixir
on the phone's own BEAM, and is a sibling of
[Sloppy Joe](https://sloppyjoe.ca), whose agent lives on your computer
instead. More at [sloppyjoe.ca/operator](https://sloppyjoe.ca/operator).

## Install (Android)

Download **[Operator.apk](https://github.com/GenericJam/operator/releases/latest/download/Operator.apk)**
from the [latest release](https://github.com/GenericJam/operator/releases/latest)
on an Android 9+ phone, open it, and allow your browser or Files app to install
it. In Operator, tap the dial for the terminal, then `[menu] › accounts` to sign
in with your own Claude or ChatGPT subscription.

> **Status:** 1.1.0, sideloaded from GitHub; not in any store. Tested on a Moto
> G 2021 (Android 11) and a physical iPhone. Expect sharp edges.

## What it can do

| | |
|---|---|
| **Agent loop** | pi-agent-core's turn loop on [req_llm](https://hex.pm/packages/req_llm): streaming, parallel tools with ordered results, steering, stop, compaction, a daily cost cap |
| **Models** | Claude (Pro/Max) and ChatGPT/Codex subscriptions via omp's own PKCE sign-in flows; a model picker like omp's `/models` in the settings menu; credentials in the platform secure store (EncryptedSharedPreferences / Keychain) |
| **Sessions** | omp/pi's session format (version 3), so a session reads the same on both sides |
| **Phone tools** | location, notifications, camera, photo picker, clipboard, HTTP, notes, artifacts for long output |
| **Attachments** | `[attach]` beside the composer: photo library, take photo, or any file; pictures go to the model as images, text inline, PDFs as documents, anything else by path |
| **Self-modification** | the Dyn layer: front screens, extra tools and the terminal theme as generations with versioned module names, a static check, selftests, screen-lock approval, probation, automatic revert, safe mode and a rescue screen |
| **The front** | a shell hosting user screens in their own process, the dial toggle as the only fixed chrome; the editable default is a welcome screen and the component library (Mishka widgets, a date picker, phone capability widgets), updated by app updates without touching your edits |
| **Onboarding** | mob's guides, the Mishka catalogue and every plugin's README ship inside the app; the agent reads them with `read_guide` / `read_doc`, and its instructions carry a compact catalogue of the library generated from the library's sources; `dyn_copy` starts a screen from a library page |
| **Voice** | hold-to-talk dictation with on-device Whisper ([mob_speech](https://hex.pm/packages/mob_speech) + [mob_whisper](https://hex.pm/packages/mob_whisper)); spoken updates when a run ends |
| **Background** | keeps a run going with the screen off (Android foreground service; iOS audio-session keep-alive) |
| **Plugins** | camera, photos, location, scanner, notify, Bluetooth, biometric, video, screencast, touch, wake, themes, Mishka, and more on the way, all available to front screens |
| **Local cluster** | Optional TLS 1.3 Erlang distribution between Operators on one private LAN: QR invite, screen-lock approval, pinned per-install certificates, peer revocation, and a bounded topic/service API. Off by default; trusted peers have full BEAM authority. See [`docs/CLUSTER.md`](docs/CLUSTER.md). |

## Moving work from your computer to the phone

Your laptop agent writes a handoff document (omp's `/handoff`); Operator turns
it into `operator://handoff` QR codes; scan them with the phone's camera and a
new session opens with the document, ready for your next message. No server,
no account.

```bash
mix operator.handoff            # latest /handoff in the current omp session, as QR codes
mix operator.login anthropic    # sign the phone in from the Mac: a QR code plus six words
```

Agents can produce handoff links themselves; the format, a reference encoder
and the limits are at
[sloppyjoe.ca/operator/agents](https://sloppyjoe.ca/operator/agents).

## Building it

You need the mob toolchain: Erlang/OTP 29, Elixir 1.20, Java 17 and the pinned
Zig dev build (all in [`.tool-versions`](.tool-versions); `mise install`
reads it). See mob's
[getting started guide](https://mob.hexdocs.pm/getting_started.html).

```bash
mix deps.get
mix mob.deploy --native --android --device <adb serial>   # build + install
mix mob.deploy --android --device <adb serial>            # Elixir-only changes
mix mob.deploy --native --ios --device <udid>             # simulator or iPhone
```

Then sign in on the phone from the terminal's `[menu]` › accounts (Claude or
ChatGPT, in the browser), or from the Mac with `mix operator.login` and scan
its QR.

Drive a running phone over Erlang distribution:

```bash
mix mob.connect --no-iex --no-restart --only <serial>
OPERATOR_SERIAL=<serial> scripts/rpc.sh 'IO.inspect(Mob.Test.screen(n))'
```

### Updates over the air

Operator's own Elixir code can be published from the Mac to phones on the same
network, signed with a key that never leaves the Mac
([mob_deliver](https://hex.pm/packages/mob_deliver)):

```bash
mix operator.deliver.key      # once per Mac
mix operator.deliver.serve    # serves updates on :8040
mix operator.deliver.qr       # scan once per phone; the phone asks before using it
mix operator.publish          # after a green gate
```

A launch that doesn't get stable rolls the update back by itself.

### Checks

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
```

## Layout

| Path | What's there |
|---|---|
| `lib/operator/core/` | the Core: agent loop, session, LLM adapters, tools, Dyn engine (`dyn/`), the front host, theme, voice, keep-alive |
| `lib/operator/*_screen.ex` | chat (terminal), menu (settings), usage, shell (front), diagnostics, rescue, QR scanner |
| `lib/operator/auth*` | provider sign-in, token refresh, QR login transfer |
| `lib/operator/cluster*`, `src/operator_{dist,epmd}.erl` | optional local TLS cluster: identity, pairing, pinning, fixed-port distribution and bounded application bus |
| `lib/mix/tasks/` | the Mac-side tasks (`operator.handoff`, `.login`, `.deliver.*`, `.publish`, `.docs`) |
| `priv/dyn_seed/` | the default front (welcome screen, component library: `showcase/components/` Mishka pages, `showcase/phone/` capability widgets), installed as a generation; a newer seed is merged in on update, user edits kept |
| `priv/docs/` | the docs bundled for the phone agent (`mix operator.docs` refreshes them) |
| `android/`, `ios/` | the native apps: approval prompt, Markdown view, secure store, deep links |
| `docs/DESIGN.md`, `docs/CLUSTER.md` | self-modification architecture; local-cluster security, operation and the headless/Nerves path |
| `PLAN.md` | what's built, what's verified on which device, and what's next |

## License

MIT, see [LICENSE](LICENSE).
