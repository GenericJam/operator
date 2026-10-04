# mob_ash

Resource-driven Mob screens from Ash. Declare Ash resources in your host app,
register the domains, get a list / detail / create screen set per resource —
Ash runs on-device in the host BEAM.

```elixir
# mix.exs
{:mob_ash, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_ash]

# config/config.exs
config :my_app, :ash_domains, [MyApp.Blog]
```

Compile and every resource in `MyApp.Blog` gets `/ash/<resource>`,
`/ash/<resource>/detail`, `/ash/<resource>/new` — shared parameterized screens
carrying the resource module as route-bound nav params. Navigate by route atom
or programmatically:

```elixir
MobAsh.navigate(socket, MyApp.Blog.Post, :list)
```

Pure Elixir (spec-v2 generated plugin, no native code): every screen is
hot-pushable. Use a device-friendly Ash data layer (`Ash.DataLayer.Ets`, or
AshSqlite over the bundled SQLite).

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.
