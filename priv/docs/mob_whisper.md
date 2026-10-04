# mob_whisper

Offline speech-to-text for [Mob](https://github.com/GenericJam/mob) apps:
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) running on the phone's
CPU, plugged into [`mob_speech`](https://hex.pm/packages/mob_speech) as an
engine.

Android's `SpeechRecognizer` belongs to the Google app: on phones where it has
no language pack (or no Google app at all) it returns nothing. mob_whisper
records the microphone itself and transcribes on the device, so dictation works
the same everywhere, offline once the model is downloaded.

## Usage

```elixir
# deps
{:mob_speech, "~> 0.1"},
{:mob_whisper, "~> 0.1"}

# mob.exs
config :mob, :plugins, [..., :mob_whisper]
```

```elixir
# once, e.g. on mount
socket = Mob.Permissions.request(socket, :microphone)

# press
socket = MobSpeech.listen(socket, engine: MobWhisper)
# release
socket = MobSpeech.stop(socket)

def handle_info({:speech, :final, text}, socket), do: ...
def handle_info({:speech, :error, reason}, socket), do: ...
```

Transcription starts when you stop, so there are no partial results; the text
arrives a moment later. Everything else (`:processing`, `:idle`, the error
reasons) is `MobSpeech`'s contract. `MobWhisper.transcribe/2` transcribes a
16 kHz PCM recording directly, without the microphone.

## The model

Downloaded on first use from a pinned revision of
[ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), checked
against its SHA-256, and kept in the app's support directory. Call
`MobWhisper.prefetch/1` at boot (or set `prefetch: true`) so the first
dictation doesn't wait for it; `prefetch(notify: self())` also reports
`{:mob_whisper, :model, :ready}` or `{:mob_whisper, :model, {:error, reason}}`
(`:network` when the download failed), so the app can tell the user.

| `model:`   | File                    | Size    | Moto G 2021 (Snapdragon 662), stop → text |
|------------|-------------------------|---------|-------------------------------------------|
| `:base_en` | `ggml-base.en-q5_1.bin` | 59.7 MB | 1.4 s (4.8 s of speech), 2.6 s (10 s)     |
| `:tiny_en` | `ggml-tiny.en-q8_0.bin` | 43.6 MB | 0.8 s (5.4 s of speech), 1.2 s (10 s)     |

`:base_en` is the default: on the sentences we tried both were near-perfect from
a speaker a few centimetres away, and base is the more robust of the two in
noise. `{:file, path}` uses a model you ship or fetch yourself.

The model isn't bundled: it would more than double a typical Mob APK, for a
feature not every user touches. The native code adds ~0.7 MB (compressed) per
ABI to the APK.

```elixir
config :mob_whisper,
  model: :base_en,   # :tiny_en | {:file, "/abs/path.bin"}
  threads: 4,        # default: min(4, CPU cores)
  prefetch: false,
  models_dir: nil    # default: Mob.Storage.dir(:app_support)/mob_whisper
```

**Android HTTPS:** the BEAM has no system CA store on Android, so load one at
boot before the download (`Mob.Certs.load_cacerts!/1`, see its docs).

## Platforms

| Platform | Status |
|----------|--------|
| Android arm64 | Device-verified (Moto G 2021, Android 11): capture (AAudio), download, transcription, cancel, permission refusal. |
| Android armv7, x86_64 emulator | Builds; not run on a device. |
| iOS | The NIF builds for device and simulator (AudioQueue capture, AVAudioSession), but it has **not run on an iPhone**. Treat it as unproven. |

English-only models; multilingual whisper models work through `{:file, path}`
with `MobSpeech`'s `:language`, untested.

## How it fits together

- `c_src/` — the NIF (`mob_whisper_nif.cpp`), microphone capture
  (`capture_android.cpp`, `capture_ios.mm`) and a vendored, CPU-only subset of
  whisper.cpp v1.9.4 (`scripts/vendor_whisper.sh` regenerates it). The host's
  native build compiles it into a static archive (a `cpp_archive` plugin NIF;
  needs mob_dev ≥ 0.7.13).
- Transcription runs on its own native thread and replies with a message: a Mob
  app's BEAM has one dirty CPU scheduler, which seconds of inference would
  otherwise hold.
- `MobWhisper.Server` owns the microphone and the loaded model, one session at
  a time.

## License

MIT. whisper.cpp and ggml are MIT too (`c_src/whisper.cpp/LICENSE`).
