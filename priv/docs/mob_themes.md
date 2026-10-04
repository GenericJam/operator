# mob_themes

Mob's default theme collection — five token-only looks in one style package:
Obsidian (default), ObsidianGlass, Citrus, Birch, Material3.

```elixir
# mob.exs
config :mob, :styles, [:mob_themes]
config :mob, :default_style, :mob_themes   # boots into Obsidian

# switch any time
Mob.Theme.set(MobThemes.Citrus)
```

Core keeps light/dark/adaptive as the neutral baseline. Nothing here is
sacred — these are decent defaults to expand on.
