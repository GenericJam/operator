# mob_scanner

QR code / barcode scanner for apps built with [Mob](https://hexdocs.pm/mob) —
extracted from mob core as a plugin. Opens a full-screen camera preview; when
a code is detected the view dismisses automatically and the result lands in
`handle_info`.

iOS: `AVCaptureMetadataOutput`. Android: CameraX + ML Kit `BarcodeScanning`
in a plugin-owned full-screen activity.

## Installation

Requires **mob_camera activated alongside** — the `:camera` runtime
permission (and the iOS `NSCameraUsageDescription` plist key) is owned by
mob_camera:

```elixir
# mix.exs
{:mob_scanner, "~> 0.1"},
{:mob_camera,  "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_camera, :mob_scanner]
```

Request `:camera` via `Mob.Permissions.request(socket, :camera)` before
scanning. If it is still undecided when `scan/2` runs, the scanner shows the
system prompt itself and opens once it is granted.

## Usage

```elixir
socket = MobScanner.scan(socket, formats: [:qr])

def handle_info({:scan, :result, %{type: :qr, value: value}}, socket), do: ...
def handle_info({:scan, :cancelled}, socket), do: ...
# camera access denied/restricted or refused at the prompt; nothing was shown
def handle_info({:scan, :permission_denied}, socket), do: ...
# the scanner couldn't open (iOS: no camera input; Android: activity launch
# failed or the host Activity was going away — cause in logcat, MobScanner tag)
def handle_info({:scan, :not_available}, socket), do: ...
```

Formats: `:qr`, `:ean13`, `:ean8`, `:code128`, `:code39`, `:upca`, `:upce`,
`:pdf417`, `:aztec`, `:data_matrix`.

## Host app requirements

None beyond activating `mob_camera` (above). The scanner `<activity>`
(`io.mob.scanner.MobScannerActivity`, AppCompat theme) is contributed to the
host `AndroidManifest.xml` by `mix mob.deploy --native` (needs mob_dev ≥ 0.6.19).
A hand-declared copy from an older setup is detected and not doubled.

## Limits

- The `formats:` option is currently ignored by both native sides (core
  parity: iOS hardcodes its metadata object types, Android scans all ML Kit
  formats). It's encoded and passed through, so honoring it later is a
  non-breaking change.

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
