# mob_vision

On-device **OCR / text recognition** for apps built with [Mob](https://hexdocs.pm/mob).
Recognizes text in a still image file — a photo captured with `mob_camera`,
picked with `mob_photos`, or any local image. Runs entirely on device: no
network, no camera session, and **no runtime permission** (it reads a file the
app already has).

iOS: the `Vision` framework (`VNRecognizeTextRequest`). Android: ML Kit
`text-recognition` (the bundled Latin recognizer — no Play Services download).

Built to grow: face and pose detection are planned on the same Vision / ML Kit
seam under `MobVision`.

## Installation

```elixir
# mix.exs
{:mob_vision, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_vision]
```

## Usage

```elixir
def handle_event("scan_receipt", %{"path" => path}, socket) do
  {:noreply, MobVision.recognize_text(socket, path)}
end

def handle_info({:vision, :text, text}, socket) do
  # `text` is the full recognized text (blocks joined by "\n", "" if none)
  {:noreply, Mob.Socket.assign(socket, :ocr, text)}
end

def handle_info({:vision, :error, reason}, socket) do
  # reason :: String.t() — e.g. "no_image" when the path is unreadable
  {:noreply, socket}
end
```

`recognize_text/3` returns the socket unchanged (fire-and-forget); the result
arrives asynchronously.

Options:

- `languages: [String.t()]` — BCP-47 hints (e.g. `["en", "fr"]`). Advisory:
  iOS prioritizes those scripts; ML Kit's default Latin recognizer ignores them.

## Limits

- v1 returns the recognized **text**. Per-block bounding boxes (for
  highlighting/overlays) are a planned follow-up.
- The default recognizer targets **Latin** scripts. Non-Latin scripts
  (Chinese/Japanese/Korean/Devanagari) need additional ML Kit models / Vision
  language config — a follow-up.
- A live-camera "read text through the viewfinder" mode is planned separately
  (it will need `mob_camera` for the `:camera` permission).

## Development

```bash
mix setup        # deps.get + activate the .githooks pre-push gate
mix test         # manifest + NIF-stub agreement (host-runnable; no device)
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — verify
on device with `mix mob.deploy --native` of a host app.

## License

MIT
