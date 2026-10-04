# mob_audio_capture

**Android only.** Meter the **device's output mix** from inside a [Mob](https://github.com/GenericJam/mob)
app — including audio produced by *other* apps and by native players (a game's own
`AudioTrack`) that bypass `Mob.Audio`.

A normal app cannot tap the global output mix with a session-0 `Visualizer`
(privileged — `ERROR_NO_INIT` on Android, device-verified), so this plugin uses the
consent-gated `MediaProjection` + `AudioPlaybackCapture` path (Android API 29+).

Because capture requires a per-session system consent dialog and a typed foreground
service, it is a **test-environment dependency** for agent-driven verification ("is
the bundled game's audio actually producing signal?"), not a capability you ship in a
production app.

> ⚠️ **iOS is not supported — and this capability is _not possible_ on iOS.** Apple
> exposes no API for one app to capture another app's or the system's audio output;
> it's a hard sandbox/privacy restriction. The iOS build is a **permanent**
> `:unsupported_on_platform` stub, not a pending feature. **If you only need to detect
> your _own_ app's audio** (e.g. a game engine running inside the Mob app), don't use
> this plugin — meter the audio at its source instead; that works on every platform and
> needs no capture API.

## Platform support

| Platform | Support |
|----------|---------|
| Android 10+ (API 29) | Full output-mix capture, subject to each source app's `allowAudioPlaybackCapture` (default-on for non-privileged API 29+ apps; `VOICE_COMMUNICATION` and DRM output never captured). |
| iOS | **Not supported — and not possible.** No public API exists for an app to capture another app's or the system's output (sandbox/privacy restriction); this is permanent, not a pending feature. Every call returns `{:error, :unsupported_on_platform}`. |

## Usage

```elixir
MobAudioCapture.start(socket)
# → handle_info({:audio_capture, :permission, :granted | :denied}, socket)

# once granted, while audio is playing anywhere on the device:
MobAudioCapture.output_level()
# => {-12.0, -3.4}   # {rms_db, peak_db}, or :silent

MobAudioCapture.stop(socket)
```

## Host setup

Add to the host app's `mob.exs` plugin list, and declare the capture service in the
host `AndroidManifest.xml` inside `<application>` (the native build also prints this
as a warning):

```xml
<service
    android:name="io.mob.audiocapture.AudioCaptureService"
    android:exported="false"
    android:foregroundServiceType="mediaProjection" />
```

`RECORD_AUDIO` must be granted at runtime before `start/1` (the manifest declaration
the plugin contributes is necessary but not sufficient — it's a runtime permission).

## Status

**Device-verified on both platforms, 2026-07-04.**

- **Android** (moto g power 2021, Android 11 / API 30) — the full lifecycle over dist
  RPC: `start/1` → MediaProjection consent → `{:audio_capture, :permission, :granted}`;
  `output_level/0` read `:silent` at rest, live `{rms, peak}` (rms ≈ −12…−18 dBFS,
  peak ≈ −2…−8 dBFS) tracking another app's audio, `:silent` on pause; `stop/1` →
  `{:error, :not_capturing}`. See `decisions/2026-07-04-android-device-verification.md`.
- **iOS** (physical iPhone SE, `aarch64-apple-ios`) — the stub links, loads, and every
  call returns `{:error, :unsupported_on_platform}`: the correct, permanent behavior.

`MobAudioCapture.DemoScreen` ships for manual spot-checks (Start + a live meter). Signed
with the shared mob first-party key and released via CI (`.github/workflows/release.yml`).
