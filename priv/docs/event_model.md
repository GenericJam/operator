# Event Model

How events flow from widgets, gestures, and lifecycle observers back to your
Elixir code. This document is the contract: native producers conform to it,
renderers map onto it, and user code reads it.

## TL;DR

- One canonical envelope: `{:mob_event, %Mob.Event.Address{}, event, payload}`
- Every event has a **target** — a pid the framework delivers to
- Default target: nearest stateful ancestor (component or screen)
- Override at registration with `target:` — accepts any pid, registered atom,
  `{:via, Registry, key}`, `:screen`, `:parent`, or `{:component, id}`
- Targets are **static at init**, never re-bound at runtime
- Stateful components own events inside their subtree; stateless components
  are transparent to event routing
- IDs accept any non-pid term (atom, binary, integer, tuple, …); prefer atoms
  for compile-time-known IDs and binaries for data-derived ones

## Address

```elixir
%Mob.Event.Address{
  screen:         atom() | pid(),    # screen module identifier
  component_path: [id()],            # [] if rooted at screen
  widget:         atom(),            # framework-defined: :button, :text_field, :list, ...
  id:             id(),              # user-supplied widget id
  instance:       id() | nil,        # repeating-widget key (list row index, grid cell)
  render_id:      pos_integer()      # monotonic counter for stale-detection
}

@type id :: atom() | binary() | integer() | float() | tuple() | map() | list()
```

### Why each field

- `screen` and `component_path` together identify the *scope of state* the
  widget belongs to. Resolved to a delivery pid at event time.
- `widget` is the kind of thing that fired: `:button`, `:text_field`, `:list`,
  `:swipe_gesture`. Always an atom — vocabulary is finite, framework-defined.
- `id` is whatever the user wrote in props (`id: :submit`, `id: "user:42"`).
  This is the human-meaningful name.
- `instance` distinguishes events from a repeating widget (list row 47 vs row
  48 with the same `id`). `nil` for non-repeating widgets.
- `render_id` lets handlers detect events from previous render generations
  (slow user, fast re-render) and ignore them.

### ID types

Anything pattern-matchable. Recommendations:

| Type | Use for | Notes |
|---|---|---|
| Atom | Compile-time-known IDs (`:save`, `:cancel`) | ✅ Cheap, fast, idiomatic |
| Binary | Data-derived IDs (`"contact:1234"`, UUIDs) | ✅ Default for dynamic IDs |
| Integer | Indices, numeric DB IDs | ✅ Cheap |
| Tuple | Compound keys (`{:user, 42}`) | ✅ Composable |
| Float | (technically allowed) | ⚠️ Float equality is fuzzy |
| Map / list | Structural keys | ⚠️ Heavy — hashed every event |
| pid / ref / fun | (forbidden) | ❌ Doesn't serialize, doesn't survive distribution |

**Atom-exhaustion warning.** Atoms are not garbage-collected. *Never* convert
a runtime string to an atom for use as an ID — `String.to_atom/1` on user data
will leak until the BEAM hits the atom table limit (default 1,048,576) and
crashes hard. Use binaries for data-derived IDs. The framework will lint for
this in dev mode.

## Stateful vs stateless components

Inspired directly by Phoenix.LiveView's split:

|  | Stateless | Stateful |
|---|---|---|
| Implementation | Plain function: `(assigns) → render_tree` | `Mob.Event.Component` (a GenServer) |
| State | None | Own assigns |
| Event handling | None — events pass through | Receives events for its subtree |
| Lifecycle | None | `mount`, `update`, `terminate` |
| Use for | Layout helpers, presentation | Behaviour encapsulation, repeating-item containers |
| Examples | `card`, `avatar`, `tag_pill` | `Mob.List`, `Mob.Form`, `Mob.DatePicker` |

**Rule:** events fired inside a stateless component's subtree resolve as if the
stateless component weren't there. Only stateful components appear in
`component_path`.

## Routing

### Default — nearest stateful ancestor

```
button(label: "Save")           # inside MyApp.CheckoutForm (stateful)
                                # which is inside MyScreen
→ resolves to: MyApp.CheckoutForm's pid
```

Resolved at **render time**, not event time. The renderer walks up the tree,
finds the first stateful ancestor, registers the tap with that ancestor's pid.
No runtime bubbling.

### Explicit target

```elixir
button(label: "Save", target: :screen)
button(label: "Pause", target: MyApp.AudioPlayer)
button(label: "Use", target: {:component, :outer_form})
button(label: "Sync", target: {:via, Registry, {:workers, "sync"}})
```

| Form | Resolves to | Validity |
|---|---|---|
| `:parent` | Nearest stateful ancestor | Always (= default) |
| `:screen` | The containing screen pid | Always |
| `{:component, id}` | A named ancestor component | Must be in ancestor chain |
| atom | Registered process by that atom | Best-effort |
| pid | That pid | Best-effort |
| `{:via, mod, key}` | Whatever `mod` resolves it to | Best-effort |

**No runtime mutation.** Once the widget is registered, its target is fixed
until the widget unmounts. To change behavior dynamically, have the target
re-dispatch based on its own state.

### In-tree vs external targets

In-tree targets (`:parent`, `:screen`, `{:component, _}`) get framework
guarantees:

- Render-id staleness check (drop events from prior render generations)
- Auto-cleanup on screen/component teardown
- Tracing integrates with the view tree

External targets (registered atom, pid, `:via` tuple) are best-effort:

- No staleness check (target's lifecycle is its own concern)
- No auto-cleanup tied to view (user owns the GenServer's lifecycle)
- If target dies or isn't registered: log + drop
- Same envelope shape — recipient pattern-matches what it cares about

## Event delivery

Every recipient gets:

```elixir
{:mob_event, %Mob.Event.Address{...}, event :: atom(), payload :: term()}
```

Examples:

```elixir
# Button tap
{:mob_event, %Address{widget: :button, id: :save}, :tap, nil}

# Text field change
{:mob_event, %Address{widget: :text_field, id: :email}, :change, "user@example.com"}

# List row selection
{:mob_event, %Address{widget: :list, id: :contacts, instance: 47}, :select, nil}

# Long press
{:mob_event, %Address{widget: :button, id: :avatar}, :long_press, %{duration_ms: 850}}

# Swipe
{:mob_event, %Address{widget: :card, id: "contact:42"}, :swipe, %{direction: :left, distance: 120}}
```

A handler matches whatever it cares about:

```elixir
def handle_event(%Address{widget: :button}, :tap, _, socket) do ...
def handle_event(%Address{id: :save}, :tap, _, socket) do ...
def handle_event(_addr, :tap, _, socket) do ...    # any tap
```

## The 1000-row pattern

Lists own their row events. The screen sees only semantic events.

```elixir
# Mob.List is a stateful component. It receives row taps, renders 1000 rows
# without 1000 processes (rows are data, not components — unless rows
# themselves are stateful, see below).

# Inside Mob.List:
def handle_event(%Address{widget: :list_row, instance: index}, :tap, _, state) do
  # Decide whether the screen needs to know.
  # Maybe maintain selection state internally:
  state = %{state | selected: index}
  # Maybe escalate:
  send_to_parent(state, :row_selected, index)
  {:noreply, state}
end

# Screen sees:
def handle_event(_addr, :row_selected, index, socket) do
  contact = Enum.at(socket.assigns.contacts, index)
  ...
end
```

**Rows that are themselves stateful components** (e.g. each row is a
swipeable card with its own dropdown) have their own pids, but must have
**stable IDs derived from the data**, not from render position:

```elixir
component(MyApp.ContactCard, id: contact.id, contact: contact)  # ✅
component(MyApp.ContactCard, id: index, contact: contact)       # ❌ identity moves on reorder
```

This is the same invariant Phoenix uses for `phx-update="stream"`.

## Stale events

Render-id is a screen-level monotonic counter. Each render bumps it. When
events fire, they carry the render-id at which the widget was registered.

```elixir
def handle_event(addr, _event, _payload, socket) do
  if addr.render_id == socket.__mob__.render_id do
    # current generation — handle normally
  else
    # stale — log and drop
  end
end
```

The framework does this check automatically for in-tree targets. External
targets receive events with the original `render_id` and can choose to ignore
or honor it.

## Lifecycle interactions

| Situation | What happens |
|---|---|
| Screen pops while event is in flight | Native handle invalidated; native side drops new events. In-flight event arrives at dead pid → silently dropped. |
| Component unmounted before event delivery | Same — dead pid, dropped. Logged in dev. |
| External target dies | `enif_send` succeeds (it's async); message goes to the void. No error. |
| Hot code reload | Address atoms still match; closures inside handlers pick up new code on next call. |

## Migration plan

The current emitters and the migration:

| Current shape | New shape | Status |
|---|---|---|
| `register_tap({pid, tag})` → `{:tap, tag}` | `{:mob_event, addr, :tap, _}` | Bridged: existing `{:tap, tag}` still arrives at screen for backward compat; new addr-based delivery added alongside |
| `register_change` → `{:change, tag, value}` | `{:mob_event, addr, :change, value}` | Bridged identically |
| `Mob.List` → `{:tap, {:list, id, :select, index}}` re-emitted as `{:select, id, index}` | `Mob.List` becomes a stateful `Mob.Event.Component`; emits `{:mob_event, addr, :row_selected, _}` to its parent | Breaking — but mechanical. Migrate one screen at a time. |
| Future: `on_long_press`, `on_swipe`, `on_double_tap` | Native-side, register through unified emitter | New — born under new scheme |

## Test ergonomics

```elixir
# Send a synthetic event without going through native:
Mob.Event.Test.send(addr, :tap, nil)

# Match a delivered event in test process inbox:
assert_receive {:mob_event, %Address{widget: :button, id: :save}, :tap, _}
```

## Tracing

```elixir
# Subscribe to ALL events for debugging:
Mob.Event.trace(:all)

# Or filter:
Mob.Event.trace(fn addr -> addr.widget == :list end)

# Returns a stream of events; useful in IEx during development.
```

## What this document doesn't cover

- High-frequency events (scroll, drag, pinch) — see PLAN.md Batch 5; needs
  throttling design before specifying envelope changes.
- Multi-stage events (drag-and-drop sessions, IME composition) — see PLAN.md
  Batch 6; likely needs its own envelope variant for session tracking.
