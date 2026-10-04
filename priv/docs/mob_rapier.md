# mob_rapier

3D physics for [Mob][mob] apps: [Rapier 3D][rapier] wrapped as a
Rustler NIF, plus a named-world registry and the face-up decode rules
the `rapier_lab` spike proved out.

Rapier is a Rust rigid-body physics engine by [dimforge][dimforge] —
production-quality, actively maintained, and fast enough to run a
tabletop scene at 30 fps on a mid-range Android device. If you have
not used it before, the [Rapier home page][rapier-home] has demos and
the [user guide][user-guide] explains the concepts one at a time.
`mob_rapier` follows Rapier's own naming; if a knob surprises you, the
matching page in Rapier's docs is the ground truth.

[mob]: https://mobframework.com
[rapier]: https://github.com/dimforge/rapier
[rapier-home]: https://rapier.rs/
[user-guide]: https://rapier.rs/docs/user_guides/rust/getting_started
[dimforge]: https://www.dimforge.com/

Extracted from [`rapier_lab`](https://github.com/GenericJam/rapier_lab)
after the API stabilised across the dice (d6, d10, d12, d20) and shells
demos — bead `rapier_lab-d00`. `rapier_lab` now depends on this package
and keeps only the demo screens; the physics primitives live here.

## What ships

- **`MobRapier.Physics`** — the Rustler NIF facade. `world_new/0`, plus
  the shape-family constructors (`add_ball`, `add_cuboid`,
  `add_static_cuboid`, `add_oblate`, `add_convex_hull`), impulses
  (`apply_impulse`, `apply_torque_impulse`), the step + read pipeline
  (`step`, `transforms`, `contacts`, `step_with_contacts_in`), and a
  by-name registry (`new_world`, `add_*_in`, `step_in`, …) that lets
  agents drive a world over Erlang distribution without dragging opaque
  NIF resource handles across the wire.

- **`MobRapier.Physics.Registry`** — the named-world storage backing the
  `_in` API.

- **`MobRapier.Dice`** — vertex tables for the d10 / d12 / d20 convex
  hulls, and the face-up decode rules for d6 / d10 / d12 / d20 dice plus
  the up/down cowrie-shell decode. Face-normal tables use the
  [dual-polyhedron][dual] identity (dodecahedron faces = icosahedron
  vertices and vice versa; trapezohedron faces = pentagonal antiprism
  vertices) so there's no separate face-normal set to keep in sync with
  vertex changes.

[dual]: https://en.wikipedia.org/wiki/Dual_polyhedron

See [guides/dice.md](guides/dice.md) for the face-up rule per shape,
and [guides/physics_tuning.md](guides/physics_tuning.md) for the
density / damping / friction / restitution defaults each dynamic body
inherits.

## Usage

```elixir
alias MobRapier.{Dice, Physics}

# One world, driven by name so agents / IEx can talk to it over dist.
:ok = Physics.new_world("dice_tray")

# A ground plane and four walls (per-wall extents; a wall is a cuboid).
_ground_id = Physics.add_static_cuboid_in("dice_tray", 1.0, 0.05, 1.0, 0.0, -0.05, 0.0)

# A d6, dropped from 20 cm above the origin.
die_id = Physics.add_cuboid_in("dice_tray", 0.015, 0.015, 0.015, 0.0, 0.20, 0.0)

# Kick it — the impulses' scale assumes the physics_tuning defaults
# (density 1000 kg/m³ → ~30 g die).
:ok = Physics.apply_impulse(       "dice_tray", die_id, 0.010, 0.000, 0.008)
:ok = Physics.apply_torque_impulse("dice_tray", die_id, 5.0e-4, 0.0,   3.0e-4)

# Tick and read back until it stops moving; then decode which face is up.
:ok = Physics.step_in("dice_tray", 1.0 / 30.0)

case Physics.transforms_in("dice_tray") do
  [{^die_id, _pos, {qx, qy, qz, qw}}] -> Dice.face_up_d6({qx, qy, qz, qw})
  _ -> nil
end
```

The `rapier_lab` demo screens (dice, shells) show the same shape end
to end — impulse, tick, read transforms, decode face-up when settled,
report it on screen.

## Host integration

`mix mob.deploy` cross-compiles the Rust crate for iOS + Android when
the host's `mob.exs` registers it as a static NIF:

```elixir
# mob.exs
config :mob_dev,
  static_nifs: [
    %{module: :lab_physics, archs: [:all]}
  ]
```

The crate name is `lab_physics` for historical reasons — renaming it
churns more than it clarifies.

On device (mob_dev's static-NIF pipeline) `Application.app_dir(:mob_rapier)`
raises because the flat OTP bundle doesn't register per-dep lib_dirs
(see [MOB-254][mob-254]). Consumers work around it by routing the
Rustler `on_load` lookup through the host's app_dir:

```elixir
# config/config.exs
config :mob_rapier, :otp_app, :my_app
```

Defaults to `:mob_rapier`, which is right for host dev + tests.

[mob-254]: https://linear.app/genericjam/issue/MOB-254

## Native crate

`native/lab_physics/` wraps [`rapier3d`][docs-rs] 0.22 behind a small
Rustler surface. Contact events flow through a `ChannelEventCollector`
per step; the buffer caps at 1024 events per channel with a
`contacts_dropped` counter for saturation detection (bead
`rapier_lab-bvr`).

[docs-rs]: https://docs.rs/rapier3d/latest/rapier3d/

The tuning surface — density, damping, friction, restitution — is a
handful of constants at the top of `src/lib.rs`. See
[guides/physics_tuning.md](guides/physics_tuning.md) for what each
knob does, why the shipped values are what they are, and where to
look in Rapier's docs when you want to override them.

## License

MIT.
