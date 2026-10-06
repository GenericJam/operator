# mob_camera

Native camera capture, live preview, and frame streaming for apps built with
[Mob](https://hexdocs.pm/mob) — `Mob.Camera`, extracted from mob core as a plugin.

iOS: `UIImagePickerController` + a shared `AVCaptureSession` (vImage frame
conversion), `AVCapturePhotoOutput` for headless stills. Android:
`TakePicture`/`CaptureVideo` activity contracts, CameraX `ImageCapture` for
headless stills.

## Platform support

| Feature | iOS | Android |
|---|---|---|
| `capture_photo/2`, `capture_video/2` | ✅ | ✅ |
| `snap/1` (headless still, no UI) | ✅ (`:no_camera` on the simulator) | ✅ |
| `start_preview/2` + `Mob.UI.camera_preview/1` | ✅ live feed | ⏳ accepted, renders nothing |
| `start_frame_stream/2` | ✅ delivers frames | ⏳ accepted, delivers nothing |

Capture works fully on both platforms today. Live preview and frame streaming
are **iOS-only** for now — on Android, `start_preview/2` and
`start_frame_stream/2` return successfully and track state, but nothing binds
a CameraX `ImageAnalysis`/`Preview` use case to that state, so no frame is
ever delivered and the preview view stays blank. No error is raised; see
[Limits](#limits) for why and what's blocking it.

## Installation

```elixir
# mix.exs
{:mob_camera, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_camera]
```

The plugin manifest merges `NSCameraUsageDescription` (iOS) and `CAMERA` /
`RECORD_AUDIO` (Android) into the host app at build time, and registers the
`:camera` permission capability — request it via
`Mob.Permissions.request(socket, :camera)` before capturing. (`:microphone`,
needed for video, stays in core.)

## Usage

```elixir
socket = MobCamera.capture_photo(socket, quality: :high)
socket = MobCamera.capture_video(socket, max_duration: 60)

def handle_info({:camera, :photo, %{path: path, width: w, height: h}}, socket), do: ...
def handle_info({:camera, :video, %{path: path, duration: seconds}}, socket), do: ...
def handle_info({:camera, :cancelled}, socket), do: ...
```

`path` is a local temp file — copy it elsewhere before the next capture.

### Headless still: `snap/1`

`snap/1` takes a photo with no preview and no shutter — for code (an agent, a
timer, a sensor trigger) that wants to see what the camera sees. Call it from
any process; the result is sent to that process:

```elixir
:ok = MobCamera.snap(facing: :back, max_size: 1600, quality: 85, flash: :off)

receive do
  {:camera, :snapped, %{path: path, width: w, height: h, facing: :back}} -> ...
  {:camera, :snap_error, reason} -> ...  # :no_camera | :permission | :busy | :background | "platform error"
end
```

The native side opens the camera, waits for exposure/focus/white balance to
settle (so the frame isn't black), shoots, releases the camera and writes an
**upright** JPEG (orientation applied to the pixels, EXIF orientation 1) to
the app's cache/temp dir. `max_size` caps the longest side (`nil` = full
sensor resolution). It never prompts for permission: request `:camera` first,
or you get `{:camera, :snap_error, :permission}`. Exactly one message arrives
per `:ok`; both platforms give up after 10 s (`:busy`/`:background` when
that's why, else an error string). Bad options return
`{:error, {:invalid_option, key, value}}` / `{:error, {:unknown_option, key}}`
and nothing is sent.

- **Android**: CameraX `ImageCapture` plus a small frame-dropping
  `ImageAnalysis` stream for 3A metering (no `Preview`) on its own
  `LifecycleOwner`, so the activity's lifecycle is untouched; core's
  `Mob.UI.camera_preview/1` view, if running, pauses while the snap holds the
  camera and resumes after. Upright by gravity (`OrientationEventListener`),
  falling back to the display rotation when the phone lies flat.
  `:background` when no activity is started (Android refuses the camera to
  background apps). `max_size: nil` decodes the full-size photo in memory.
- **iOS**: a private `AVCaptureSession` + `AVCapturePhotoOutput` (no preview
  layer), upright by gravity (`AVCaptureDeviceRotationCoordinator`). `:busy`
  while the shared `start_preview/2` / `start_frame_stream/2` session runs —
  it keeps running after `stop_frame_stream/1` until `stop_preview/1` — or a
  `capture_photo/2` / `capture_video/2` picker is open. `max_size: nil` uses
  the largest photo size the format supports (up to 48 MP). The simulator
  has no camera: `:no_camera`.

For real-time work (object detection, AR, custom filters), stream frames
(**iOS only** — see [Platform support](#platform-support)):

```elixir
socket = MobCamera.start_frame_stream(socket, width: 640, height: 640, format: :rgb_f32)

def handle_info({:camera, :frame, %{bytes: bin, width: w, height: h,
                                    format: :rgb_f32, timestamp_ms: _t,
                                    dropped: _n}}, socket) do
  # :rgb_f32 is Nx-ready: Nx.from_binary(bin, :f32) |> Nx.reshape({1, h, w, 3})
end
```

Resize + format conversion happen natively, and late frames are dropped
natively, so the BEAM mailbox stays bounded. Other options: `format: :bgra_u8`,
`facing: :front`, `throttle_ms:`. Stop with `MobCamera.stop_frame_stream/1`.

Live preview pairs a session from this plugin with a view component from core
(**iOS only** — see [Platform support](#platform-support)):

```elixir
socket = MobCamera.start_preview(socket, facing: :back)
# in render/1:
{Mob.UI.camera_preview(facing: :back)}
```

## Host app requirements

Photo/video capture saves through a FileProvider: `AndroidManifest.xml` must
declare an `androidx.core.content.FileProvider` `<provider>` with
`res/xml/file_provider_paths.xml`. mob_new-generated apps include it;
hand-rolled hosts must add it or capture returns `:cancelled`.

## Limits

- **Android live preview and frame streaming are not implemented — only
  state tracking is.** `camera_start_preview`/`camera_start_frame_stream` in
  `MobCameraBridge.kt` set fields and bump a revision counter; nothing binds
  a CameraX `Preview`/`ImageAnalysis` use case to the capture session, so
  `deliverFrame` (which would forward pixel data to the BEAM) is never
  called. `start_preview/2` and `start_frame_stream/2` both return
  successfully — there is no error, the calls just have no effect on
  Android. Capture (`capture_photo/2`, `capture_video/2`) is unaffected and
  fully implemented on both platforms.
- The preview *view* node (`Mob.UI.camera_preview/1`) stays in mob core for
  now — this plugin owns the session (`start_preview/2` / `stop_preview/1`).
  Moving the view here, and wiring the Android CameraX binding above, both
  wait on the plugin native-view capability.
- Frame size is capped at ~4 MP; mismatched aspect ratios are center-cropped
  on the long axis before scaling. `width: nil, height: nil` (both) delivers
  the camera's native resolution uncropped and unscaled (upright portrait).
  (iOS only — see above.)

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
