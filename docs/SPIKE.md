# Operator feasibility spike (2026-10-02)

Can a mob app run an omp-style coding agent entirely on the phone: a Jido.AI
ReAct loop, OpenRouter sign-in, and self-modification by compiling its own
code? Tested on the Android emulator `Pixel_8_arm` (API 35, arm64, 4 vCPU),
mob 0.9.10 / mob_dev 0.7.9, OTP 29, Elixir 1.20.1. iOS not tested (simulators
unusable host-wide). Evidence files are in `docs/spike/`.

## Verdict

| Question | Answer |
|---|---|
| jido 2.3.3 / jido_ai 2.3.0 / req_llm 1.26.0 on device | **Yes**, after three on-device fixes (llm_db snapshot, time_zone_info data, Jido instance). |
| LLMDB model lookup | **Yes** (OpenRouter-only snapshot, 632 models). |
| Start a Jido.AI agent with a Jido.Action tool, no network | **Yes**, 12.6 ms. |
| `:compiler` + Elixir compiler shipped | **Yes**, in the default (non-slim) build. `MOB_SLIM=1` strips `compiler` (and `mnesia`); keep them with `config :mob_dev, slim: [keep_libs: ["compiler", "mnesia"]]`. |
| Compile a Mob.Screen on device, load it, navigate to it | **Yes**. |
| ExUnit-free selftest on device | **Yes**; failing selftests and syntax errors are refused and not persisted. |
| Survive a restart (persist source, recompile at boot) | **Yes**. |
| OpenRouter PKCE, localhost callback | **Works** (Chrome → BEAM listener on `127.0.0.1:51423` → exchange to openrouter.ai), with one Android 15 catch (below). Real sign-in **pending Kevin**. |
| Streamed model call, tool-call round trip | **Not run**: needs the key (pending sign-in). Code ready: `Operator.Diag.stream/1`, `Operator.Diag.tool_roundtrip/1`. |

## Numbers

**Size** (debug APK; dev deploys push BEAMs over adb, so the APK doesn't hold them):

| | baseline (`mob.new --blank`) | with agent stack + mob_biometric |
|---|---|---|
| debug APK | 77.6 MB | 85.1 MB (+7.5 MB, native plugin + icon) |
| BEAMs on device | 10.4 MB | 58.6 MB raw, 27.5 MB zipped (incl. ~300 dev-only modules from mob_dev's deps that a release drops) |
| `LLMDB.Packaged` with `compile_embed: true` | | 12.9 MB beam (1.9 MB gzipped) |
| `Operator.LLMCatalog` (OpenRouter-only trim) | | 1.2 MB beam |

**Boot** (`Operator.Boot`, ms, `docs/spike/boot-timings.txt`; cold launch to
first frame `am start -W` 1.6–2.5 s, then on_start runs before the root
screen shows):

| | apps start | first LLMDB lookup | selfmod recompile (2 modules) | BEAM uptime at end of boot |
|---|---|---|---|---|
| 1 scheduler (mob default `-S 1:1`), `compile_embed: true` | 2.5–3.0 s | **18.8–20.0 s** | 0.3–4.3 s | 24–28 s |
| 1 scheduler, OpenRouter-only snapshot | 2.1 s | 2.9–3.3 s | 1.4–2.1 s | 8.2–9.2 s |
| `--schedulers 0` (4 online) | 2.6 s | 1.7–2.0 s | 1.1–1.3 s | 7.5–8.0 s |

(One early 1-scheduler `compile_embed` boot measured 2.4 s for LLMDB / 3.3 s
total; it never reproduced, so treat it as an outlier.) BEAM memory after
boot: 191 MB (`:erlang.memory(:total)`, with the full catalog).

**On-device compile** (`Code.compile_string/2`, warm, `step3-compile-timings.txt`):
43-line screen 57–82 ms; 224-line screen 180–280 ms. The first compile after
a launch is 1–2 s slower (compiler modules load cold).

**OAuth exchange**: transport works; real latency pending.

## What broke and how it's fixed

1. **llm_db's snapshot** (`priv/llm_db/snapshot.json`, 10 MB, 230 providers)
   isn't shipped (mob_dev ships deps' ebins, not priv/). `compile_embed: true`
   works but costs a 12.9 MB beam and ~19 s first lookup. Fix used:
   `Operator.LLMCatalog` trims the snapshot to `openrouter` at compile time
   (1.1 MB, recomputed `snapshot_id`, strict integrity still on), writes it to
   the data dir at boot and sets `:snapshot_path`. Filtering with `allow:` does
   not help: llm_db loads everything first.
2. **time_zone_info** (jido scheduler dep) reads `:code.priv_dir/1` →
   `{:error, :bad_name}` → `TimeZoneInfo.Worker` crashes and so does
   `ensure_all_started(:jido_ai)`. Fix: `Operator.TzData` embeds `data.etf`
   and uses `TimeZoneInfo.DataPersistence.FileSystem`.
3. **Jido 2 needs an instance** (`use Jido, otp_app:`); `Jido.AgentServer.start/1`
   without one fails with `noproc Jido.AgentSupervisor`. `Operator.Jido`.
4. **DNS**: BEAM's pure DNS fails on the emulator; `Mob.DNS.resolve("openrouter.ai")`
   at boot (muster_app's pattern).
5. **Android 15 blocks a backgrounded app's outbound network** ~60 s after
   it leaves the foreground (`docs/spike/step4-background-network.txt`:
   connect OK right after switching to Chrome, timeout after 60 s, OK again
   in the foreground). The localhost callback still arrives (loopback isn't
   blocked) but the exchange can't reach openrouter.ai until the user
   switches back. Fix: the exchange runs in a task and retries transport
   errors every 2 s for up to 9 min; the callback page says "switch back to
   Operator". Probe: a fake code sent through Chrome to the callback after
   70 s in the background took 3 attempts and ended with OpenRouter's own
   `400 Invalid code` once Operator was in front
   (`step4-localhost-callback-probe.txt`). **Implication for the agent**: a
   long model call or tool run will lose its network if the user leaves the
   app; the real build needs a foreground service (or to accept "agent
   pauses in the background").
6. mob_dev: a `--native` redeploy on an emulator where `adb root` is active
   pushes OTP as root with a stale SELinux MCS category (from the previous
   install's uid), then its ERTS preflight runs before its own relabel and
   fails "OTP runtime missing". Workaround: `adb shell "chcon -hR $(stat -c %C
   /data/data/<pkg>/cache) /data/data/<pkg>/files/otp"`, then a plain deploy.
   Worth a mob_dev issue.
7. Smaller: the generated `~MOB(...)` sigil ends at the first `)`, so no
   function calls inside the paren form; `Mob.Storage.dir(:cache)` files get
   purged by installd when the emulator disk is low (fine for per-boot files,
   not for state); the key and the self-written sources live in
   `MOB_DATA_DIR`.

## What is in the app

- `Operator.Boot`: timed boot steps (DNS, tz data, catalog, CA certs, agent
  apps, Jido instance, repo, key, OAuth server, selfmod recompile).
- `Operator.Agent` (`use Jido.AI.Agent`, model alias `:operator`, resolved at
  agent start) + `Operator.Tools.AddNumbers`.
- `Operator.SelfMod`: `compile/2`, `install/2` (compile → selftest → persist
  only on pass), `recompile_all/0` at boot, sources in
  `<MOB_DATA_DIR>/selfmod/<name>.ex`. Samples in `priv/selfmod_samples/`.
- `Operator.OpenRouter.OAuth`: PKCE S256, localhost listener on port 51423
  (`:gen_tcp`, no Bandit), headless paste fallback, async exchange.
- `Operator.KeyStore`: **spike storage, not the secure store**: a 0600 file in
  the app's private data dir. muster_app's Keychain/EncryptedSharedPreferences
  store is a static C NIF plus Kotlin (`c_src/muster_secure_store.c`,
  `MusterSecureStore.kt`); porting it is native work for the real build.
  Only a SHA-256 fingerprint ever leaves the module.
- `Operator.Diag`: the probes used here. `scripts/rpc.sh`: dist rpc.
- mob_biometric is activated (trusted key in `mob.exs`) but not yet wired.
- `mob.exs` now has `beam_flags: "-S 0:0"` (all cores) from the scheduler
  test; battery impact unmeasured.

## Resume the sign-in (pending)

1. `agent-lease acquire <name> --serial emulator-5554` (boot `Pixel_8_arm`
   if needed: `emulator -avd Pixel_8_arm -no-snapshot-load &`), then
   `mix mob.connect --no-iex --no-restart --only emulator-5554`.
2. Chrome on the emulator has first-run disabled
   (`/data/local/tmp/chrome-command-line`).
3. Kevin: open Operator, tap **Sign in with OpenRouter**, sign in, approve,
   then switch back to Operator (recents). Fallback: **Sign in (show code to
   paste)**, paste the code, **Submit pasted code**.
4. Check: `scripts/rpc.sh 'IO.inspect(:rpc.call(n, Operator.OpenRouter.OAuth, :status, []))'`
   until `phase: :signed_in` (shows `exchange_ms`, never the key).
5. Model calls (Operator in the foreground):
   `scripts/rpc.sh 'IO.inspect(:rpc.call(n, Operator.Diag, :stream, [], 120_000))'`
   and `… Operator.Diag, :tool_roundtrip, [], 180_000 …`. Default model
   `openrouter:google/gemma-4-31b-it:free`; pass e.g.
   `["openrouter:openai/gpt-5-nano"]` if free models are rate-limited, or
   `["openrouter:anthropic/claude-haiku-4.5"]`.

## Recommended architecture for the real build

**Process shape.** `Mob.Screen.start_root/1` first, then boot the agent stack
in a supervised task (today on_start blocks the first frame for 7–9 s). One
`Operator.Jido` instance; one `AgentServer` per session.

**Session format and storage.** SQLite (already in the app via ecto_sqlite3):
`sessions` (id, title, model, created/updated) and an append-only `entries`
table (session_id, seq, kind = user | assistant | tool_call | tool_result |
system | selfmod_event, JSON payload, token usage). That's omp's JSONL
session model in a table: replayable into a ReqLLM context, cheap to append
during streaming, queryable for the UI. Large blobs (photos) as files under
`MOB_DATA_DIR/blobs/<sha256>`, referenced from the payload.

**Self-modification safety.**
- *Protected rescue path* (shipped in the APK/OTA bundle, never written by
  the agent): boot, Operator.SelfMod itself, the session store, sign-in, the
  agent loop, a "Safe mode" screen, and the approval screen. Self-written
  modules live under one namespace (`Operator.Dyn.*`) and may not redefine
  anything else: reject source whose `defmodule`s fall outside it (check the
  quoted AST before compiling) or that calls `:code`, `File` outside its
  sandbox dir, `System.cmd`, etc. (an AST allowlist, not a sandbox: the BEAM
  has no in-process isolation, so the allowlist plus approval is the gate).
- *Generations, not files*: `selfmod/gen-<n>/` holds a full set of sources +
  a manifest (sha256s, selftest results, approver, timestamp); `current` is a
  pointer file written atomically after the selftests pass **and** Kevin
  approves with mob_biometric. Boot loads `current`.
- *Rollback without a server*: boot writes `booting=<gen>` before loading,
  clears it once the root screen has rendered and stayed up ~10 s. If boot
  finds a stale `booting` marker (crash loop) it loads the previous
  generation and shows "rolled back". Safe mode (hold a button at launch, or
  two failed boots) loads no `Dyn` code at all. A manual "revert to
  generation N" is a pointer flip. Keep the last ~10 generations.
- *Biometric gate*: the agent can draft and selftest freely; promoting a
  generation to `current` (and any new tool that touches camera, location,
  network, or files) requires `MobBiometric.authenticate/2` on a screen that
  shows the diff. The key store (once native) is also biometric-bound.

**Background.** Decide between an Android foreground service for long
agent runs and "pause on background, resume on foreground"; the network
block above makes silent background work impossible otherwise.
