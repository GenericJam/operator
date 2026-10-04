# mob_photos

Photo / video library picker for apps built with [Mob](https://hexdocs.pm/mob)
— extracted from mob core as a plugin.

iOS: `PHPickerViewController` (iOS 14+). Android: the system Photo Picker
(`PickMultipleVisualMedia`). Both run out of process, so no runtime permission
dialog is ever shown and no usage-description string is needed.

## Installation

```elixir
# mix.exs
{:mob_photos, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_photos]
```

The plugin manifest merges `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` /
`READ_EXTERNAL_STORAGE` into the host AndroidManifest at build time — the
system picker doesn't need them, but they cover OEM fallback pickers on
API <= 32. No iOS plist key.

## Usage

```elixir
socket = MobPhotos.pick(socket, max: 5)

def handle_info({:photos, :picked, items}, socket) do
  # each item: %{path: "/tmp/mob_pick_xxx.jpg", type: :image | :video,
  #              width: 1920, height: 1080}
end

def handle_info({:photos, :cancelled}, socket), do: ...
```

## Limits (platform parity, inherited from core)

- iOS items carry only `path` + `type` (no `width`/`height`; `type` is an
  atom).
- Android items carry all four keys, but `type` is a string
  (`"image"`/`"video"`) and `width`/`height` are `0` — the picker doesn't
  probe dimensions.
- The `types:` option is currently ignored by both native sides; both pickers
  show images + videos.

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
