# mob_location

Device location (GPS / network) for apps built with
[Mob](https://hexdocs.pm/mob) — extracted from mob core as a plugin.

iOS: `CLLocationManager`. Android: `FusedLocationProviderClient`.

## Installation

```elixir
# mix.exs
{:mob_location, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_location]
```

The plugin manifest merges `NSLocationWhenInUseUsageDescription` (iOS) and
`ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` (Android) into the host app
at build time, and registers the `:location` permission capability — request
it via `Mob.Permissions.request(socket, :location)` before use.

## Usage

```elixir
socket = MobLocation.get_once(socket)                     # single fix, then stop
socket = MobLocation.start(socket, accuracy: :balanced)   # continuous updates
socket = MobLocation.stop(socket)                         # save battery

def handle_info({:location, %{lat: lat, lon: lon, accuracy: acc, altitude: alt}}, socket), do: ...
def handle_info({:location, :error, reason}, socket), do: ...
```

`accuracy:` is `:high | :balanced | :low` (default `:balanced`). Error
`reason` atoms: `:permission_denied` (user denied or revoked `:location`)
and `:unavailable` (the OS can't get a fix right now).

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
