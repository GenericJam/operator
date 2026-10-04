# Mob's rules for app code

From mob 0.9.12's AGENTS.md (written for agents working on mob itself): the parts that hold for app code. Rules about mob's own repo, native code and releases are left out.

## What Mob is, in one paragraph

Mob lets you write iOS and Android apps in Elixir, with the BEAM running
on-device. The phone hosts an Erlang node — a real one, distribution-capable,
introspectable, hot-code-loadable. Two modes: a SwiftUI/Compose UI driven by
Elixir GenServers (Mob UI apps), or a sidecar BEAM embedded in a normal native
app to give agents and tests live access (Mob as test harness). The sidecar
mode is the long-term bet. Both modes produce a real Erlang node you can `Node.connect/1` to.

For the *why* (the BEAM-on-mobile pitch), see `guides/why_beam.md`.

**Default arguments evaluate eagerly.** `System.get_env("ROOTDIR", Path.expand("~/..."))`
evaluates `Path.expand` *every call*, regardless of whether `ROOTDIR` is set.
`Path.expand("~/...")` calls `System.user_home!()` which raises on Android
(no `HOME` env var). Use `case System.get_env(...)` or `||` instead. Burned us
once — see commit `d77932e`.

**Compile-time `~r//` literals are unsafe on OTP 28.** They bake a
`:re_exported_pattern` and call `:re.import/1` at runtime; OTP 28.0 removed
that function. Use `Regex.compile!("...", "flags")` to compile at runtime.
71 literals across mob_dev were swept in 0.3.17.

- **Write UI the LiveView way.** The `~MOB` sigil supports `@assigns` shorthand
and `:if` / `:for` control attributes (`<Row :for={u <- @users}>`), and
`Mob.Socket` has `assign/2,3`, `update/3`, `assign_new/3`. See
`guides/components.md` → Control flow.

## Don't write this slop

LLMs reach for the same anti-patterns over and over. The list below is the
shape of code our `mix credo --strict` (via `ex_slop`) refuses to merge — but
catching it post-hoc costs a round-trip. Don't write it in the first place.

**Error handling**
- No blanket `rescue _ -> nil` or `rescue _e -> {:error, "..."}`. Rescue the
  specific exception or let it crash.
- No `rescue e -> Logger.error(...); :error` — that logs the bug into oblivion.
  Either reraise or return a typed error tuple the caller can match on.
- No `try/rescue` around functions that don't raise (`Map.get`, `Enum.find`,
  `String.split`). Look up whether the function actually raises before wrapping it.

**Database access**
- Filter in SQL, not in Elixir: `from(u in User, where: u.active)` —
  not `Repo.all(User) |> Enum.filter(& &1.active)`.
- No N+1 in `Enum.map`: don't `Enum.map(ids, &Repo.get(...))`. Use `Repo.all(from … where: id in ^ids)`.
- Don't write a GenServer whose entire job is `Map.get`/`Map.put` on state —
  use ETS, Agent, or a struct passed by value.

**Maps**
- Pick one key type per map. Don't `Map.get(m, :key) || Map.get(m, "key")` —
  normalize once at the boundary.
- Iterate the map directly. Not `Map.keys(m) |> Enum.map(fn k -> m[k] end)`.

**Enum / list idioms** — use the function that exists:
- `Enum.reject(&is_nil/1)`     not `Enum.filter(&(&1 != nil))`
- `Enum.empty?(x)`             not `length(x) == 0`
- `List.last(x)` / `Enum.at(x, -1)` not `Enum.at(x, length(x) - 1)`
- `Map.new/2`                  not `Enum.reduce(%{}, fn ..., &Map.put/3)`
- `Enum.into(list, %{})`       only if you actually have a Collectable target;
  for a plain literal target it's just `Map.new`.
- `Enum.filter`                not `Enum.flat_map(fn x -> if cond, do: [x], else: [] end)`
- `Enum.sum`                   not a hand-rolled reduce with `+`
- `Enum.max` / `Kernel.max`    not `if a > b, do: a, else: b`
- `Enum.sort(list, :desc)`     not `Enum.sort(list) |> Enum.reverse()`
- `Enum.min(list)`             not `Enum.sort(list) |> Enum.at(0)`
- `Enum.map_join(list, sep, &f/1)` not `Enum.map(list, &f/1) |> Enum.join(sep)`

**`with` blocks**
- No identity `else` clause. `with :ok <- foo() do :ok end` — drop the
  `else err -> err` part.

**Strings**
- `String.length(s)` not `length(String.graphemes(s))`.
- For counting specific ASCII chars, prefer `:binary.matches/2` over graphemes.
- No manual string reverse via graphemes + reverse + join — use `String.reverse/1`.

**Paths**
- `Application.app_dir(:my_app, "priv/...")` over `Path.expand("...priv...", __DIR__)`.
  The Mix-task code in `mob_dev` is an exception — it needs cwd-relative paths
  for the *user's* project.

**Docs and comments**
- No "This module provides functionality for..." moduledoc. State *why* it
  exists or what's surprising; if there's nothing to say, omit it.
- No obvious comments (`# Fetch the user` above `Repo.get(User, id)`).
- No narrator comments (`# We need to...`, `# Here we...`).
- No step comments (`# Step 1: Do X`, `# Step 2: Do Y`) — function names cover that.
- No `@doc false` on a `defp` — private already means undocumented.
- Boilerplate `## Parameters / ## Returns` sections are noise unless the
  parameters are non-obvious.

**Code shape**
- Don't shadow `Kernel` functions with local variables named `length`, `min`,
  `max`, `node`, etc.
- Don't rebind a parameter inside the function body. Pick a new name.
- Don't write `x = foo(); x` at the end of a function — just `foo()`.
- Don't extract `[a, b] = list` only to immediately rebuild `[a, b]`.
- Use the same name for the same parameter across all clauses of a function.
