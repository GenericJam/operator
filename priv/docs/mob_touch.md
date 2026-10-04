# mob_touch

Stream the user's raw screen touches (x/y) to a [Mob](https://github.com/GenericJam/mob)
screen.

Per-widget `on_tap` only fires for a tapped button. `mob_touch` observes **every
touch on the app surface** and reports its coordinates — for drawing, custom
gestures, joysticks, heatmaps, and the like. It **observes without consuming**,
so buttons and scrolling keep working while you stream. No runtime permission.

## Usage

```elixir
# in a screen
def handle_info({:tap, :start}, socket), do: {:noreply, MobTouch.start(socket)}

def handle_info({:touch, %{phase: phase, x: x, y: y, pointer: p}}, socket) do
  # phase: :down | :move | :up | :cancel
  # x, y:  dp (logical px), origin top-left — the layout's coordinate space
  # p:     stable id per finger (multi-touch); ignore for single-finger use
  {:noreply, draw(socket, x, y)}
end

# later
MobTouch.stop(socket)
```

`start/2` takes `throttle_ms:` (default 16 ≈ 60 Hz) — the minimum gap between
`:move` deliveries; `:down`/`:up`/`:cancel` are never throttled.

## Install

```elixir
# mix.exs
{:mob_touch, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_touch]
config :mob, :trusted_plugins, %{mob_touch: "ed25519:<fingerprint>"}
```

`mix mob.plugin.trust mob_touch` records the fingerprint, then
`mix mob.deploy --native`.

## How it works

- **Android:** wraps the Activity window's `Window.Callback` with a reflective
  proxy that observes `dispatchTouchEvent` and forwards it on. Coordinates are
  px ÷ density → dp.
- **iOS:** a passive `UIGestureRecognizer` on the key window with
  `cancelsTouchesInView = NO` that never recognizes, so it sees every touch
  while the app still receives them.

Touches are observed **app-wide** (the window, not a single widget) — that's the
only thing the native layer can give cheaply, and it's what arbitrary-coordinate
features need. For *injecting* synthetic touches (test automation), use mob
core's `Mob.Test` harness over Erlang distribution; that's a separate concern.

## License

MIT.
