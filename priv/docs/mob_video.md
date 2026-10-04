# mob_video

On-device video processing for [Mob](https://github.com/GenericJam/mob) apps,
backed entirely by the platform video toolkits — **no ffmpeg**.

Android uses `MediaExtractor` / `MediaMuxer` / `MediaMetadataRetriever`; iOS uses
`AVFoundation` (`AVAssetExportSession` passthrough, `AVAssetImageGenerator`). The
operations here are the ones the OS does natively, losslessly, and
hardware-accelerated.

## Operations

```elixir
# All async — results arrive in handle_info/2. dst paths go under app storage
# (e.g. Mob.Storage.dir(:cache)); src is a local file path.

MobVideo.probe(socket, src)
#=> {:video, :info, %{duration_ms:, width:, height:, rotation:,
#                     has_audio:, bitrate:, frame_rate:}}

MobVideo.clip(socket, src, dst, start_ms: 1_000, end_ms: 5_000)
#=> {:video, :clipped, %{path:, duration_ms:}}      # stream copy, no re-encode

MobVideo.thumbnail(socket, src, dst, at_ms: 2_000, max_width: 480)
#=> {:video, :thumbnail, %{path:, width:, height:}}

MobVideo.extract_audio(socket, src, dst)
#=> {:video, :audio_extracted, %{path:}}
```

Errors come back as `{:video, :error, reason}` where `reason` is `:not_found`,
`:unsupported`, `:io_error`, or `:bad_range`.

## Install

```elixir
# mix.exs
{:mob_video, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_video]
config :mob, :trusted_plugins, %{mob_video: "ed25519:<fingerprint>"}
```

Run `mix mob.plugin.trust mob_video` to record the fingerprint, then
`mix mob.deploy --native`.

## Why no ffmpeg

A clipper, a thumbnailer, an audio-extractor and a prober are all **stream-copy
or single-frame-decode** operations — the platform does them for free, losslessly,
and with the hardware codecs. ffmpeg would add tens of MB to the app, drag in the
GPL/App-Store licensing problem (its useful encoders are GPL), need a hand-rolled
cross-compile now that ffmpeg-kit is archived, and run video encode in slow
software. None of that buys anything for the operations above.

ffmpeg only earns its weight for **re-encoding, filters, overlays, and
concat-across-codecs** — deliberately out of scope here. If you need those later,
they slot in behind this same plugin's API; the cheap, common 80% should not pay
ffmpeg's cost.

## Permissions

Processing a file the app can already read needs no runtime permission. Reading
from the shared media store needs `READ_MEDIA_VIDEO` (Android 13+) / Photos
access (iOS) — pick through `mob_photos` first and hand the resulting local path
here.

## License

MIT.
