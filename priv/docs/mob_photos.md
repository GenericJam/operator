# mob_photos

Photo / video library access for apps built with [Mob](https://hexdocs.pm/mob)
— extracted from mob core as a plugin:

- `MobPhotos.pick/2` — the system picker. iOS: `PHPickerViewController`
  (iOS 14+). Android: the system Photo Picker (`PickMultipleVisualMedia`).
  Both run out of process, so no permission dialog is shown.
- `MobPhotos.list_media/2` — the newest photos/videos in the library with
  metadata (Android `MediaStore`, iOS `PHAsset`), no picking needed. Needs the
  `:media` permission.
- `MobPhotos.thumbnail/2` — a downscaled, upright JPEG of one image plus its
  metadata: dimensions, capture time, GPS, camera make/model. Synchronous.

## Installation

```elixir
# mix.exs
{:mob_photos, "~> 0.2"}

# mob.exs
config :mob, :plugins, [:mob_photos]
```

The plugin manifest merges `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` /
`READ_EXTERNAL_STORAGE` / `ACCESS_MEDIA_LOCATION` into the host
AndroidManifest at build time, and a placeholder
`NSPhotoLibraryUsageDescription` into `Info.plist` — replace that string (App
Store review rejects the placeholder on purpose).

## Usage

### Pick

```elixir
socket = MobPhotos.pick(socket, max: 5)

def handle_info({:photos, :picked, items}, socket) do
  # iOS:     %{path: "/tmp/mob_pick_xxx.jpg", type: :image, name: "IMG_0042",
  #            size: 2_481_233, width: 4032, height: 3024}
  # Android: %{path: ".../cache/mob_pick_xxx.jpg", type: "image", name: "1000000021.jpg",
  #            size: 2_481_233, width: 4032, height: 3024}
end

def handle_info({:photos, :cancelled}, socket), do: ...
```

### List the library

```elixir
socket = Mob.Permissions.request(socket, :media)

def handle_info({:permission, :media, :granted}, socket) do
  {:noreply, MobPhotos.list_media(socket, type: :image, limit: 20)}
end

def handle_info({:media, :listed, items}, socket) do
  # newest first; each item:
  # %{uri: "content://media/external/images/media/42",   # iOS: "ph://<localIdentifier>"
  #   display_name: "IMG_0042.jpg", size: 2_481_233, mime_type: "image/jpeg",
  #   date_added: 1_700_000_000, date_taken: 1_699_999_000_123,
  #   width: 4032, height: 3024, type: "image"}
end
```

`size`, `date_taken`, `width` and `height` are left out of an item when the
platform doesn't know them — read them with `item[:date_taken]`.

### Thumbnail + metadata

```elixir
{:ok, info} = MobPhotos.thumbnail(item.uri, max_size: 1280, quality: 80)
# %{path: ".../cache/mob_thumb_3fc29d7f5e251c42.jpg", width: 960, height: 1280,
#   orig_width: 3000, orig_height: 4000, mime: "image/jpeg", size: 196_758,
#   taken_at: "2024-05-01T12:34:56-07:00",
#   latitude: 49.2827, longitude: -123.1207, altitude: 70.5,
#   make: "TestCam", model: "Probe 1"}
```

`source` can be an absolute path (e.g. a picked item's `path`), an Android
`content://` URI or an iOS `ph://` id. The caller waits while the image is
decoded on a native worker thread (never a BEAM scheduler). Errors:
`{:error, :not_found | :unsupported | :permission | :timeout}` or
`{:error, message}`.

## Limits

- Picker items: `type` is an atom on iOS and a string on Android (inherited
  from core). Android videos report `width`/`height` `0`; iOS videos omit
  them.
- The `types:` option of `pick/2` is ignored by both native sides; both
  pickers show images + videos.
- Android's photo picker strips GPS from the files it hands out, so
  `thumbnail/2` of a picked item has no location; list the library with
  `list_media/2` (the `:media` grant includes `ACCESS_MEDIA_LOCATION`) to get
  it.
- `thumbnail/2` handles images only; videos return `{:error, :unsupported}`.

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
