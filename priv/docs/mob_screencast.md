# mob_screencast

Capture the device's **own screen** as an H264 stream, from inside an app
built with [Mob](https://hexdocs.pm/mob) — the in-app replacement for
host-side `adb screenrecord`, so a NAT'd phone can publish its screen with no
adb and no host on the same network.

The native side captures the display (Android `MediaProjection`, iOS
`ReplayKit`) and hardware-encodes it on-device (`MediaCodec` /
`VideoToolbox`), so the BEAM receives ready-to-send Annex-B H264 NAL units
rather than raw frames — they drop straight into a WebRTC RTP payloader.

## Installation

```elixir
# mix.exs
{:mob_screencast, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_screencast]
```

Screen capture needs explicit per-session user consent (Android's
MediaProjection system dialog, iOS ReplayKit's prompt) — `start_stream/2`
triggers it; there's no manifest permission to request. The manifest merges
the Android foreground-service permissions the capture runs under.

## Usage

```elixir
socket = MobScreencast.start_stream(socket, bitrate: 2_000_000, max_size: 1280)

def handle_info({:screencast, :permission, granted_or_denied}, socket), do: ...

def handle_info({:screencast, :frame, %{bytes: nal_units, format: :h264,
                                        timestamp_ms: t, keyframe: kf?}}, socket) do
  # bytes: one Annex-B access unit (00 00 00 01 start codes);
  # keyframe frames are prefixed with SPS/PPS
end

socket = MobScreencast.stop_stream(socket)
MobScreencast.request_keyframe()   # force an IDR when a new viewer joins
```

Options: `:bitrate` (bits/sec, default `2_000_000`), `:max_size` (cap the
longer screen edge in px, default native resolution), `:fps` (default `30`),
`:keyframe_interval_ms` (default `2000`).

## Host app requirements

`AndroidManifest.xml` must declare the capture service inside
`<application>`:

```xml
<service android:name="io.mob.screencast.ScreencastService"
         android:exported="false"
         android:foregroundServiceType="mediaProjection" />
```

MediaProjection capture must run in a typed foreground service; without the
declaration the app builds and boots fine, then throws a `SecurityException`
at first capture.

## Limits

- `:max_size` is honored on **Android only** — the iOS encoder currently
  captures at native resolution.

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.

## License

MIT
