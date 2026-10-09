# 3D scenes and physics in a front screen

How to put a 3D scene (`Mob.Scene3d`) with real physics (`MobRapier.Physics`)
on a front screen in Operator. This guide is about this app; where the
`mob_scene3d` and `mob_rapier` guides say otherwise, this one wins.

## The shape of it

- The screen holds a physics **world** (`MobRapier.Physics.world_new/0`) in
  its assigns, steps it on a timer, reads the bodies' transforms back, and
  renders them as a `Mob.Scene3d` scene: one `Mob.Scene3d.viewport/1` node
  whose `ir:` is built from assigns on every render.
- Rapier and Filament never talk to each other: your screen is the bridge.
  Physics positions are metres, Y is up, rotations are quaternions
  `{qx, qy, qz, qw}`, and the scene uses the same conventions, so a body's
  `{pos, rot}` goes straight into its entity's `Transform`.

## Don't use the named-world API

`Physics.new_world/1` and the `*_in` functions (`add_cuboid_in`,
`step_in`, `transforms_in`, ...) store worlds in `MobRapier.Physics.Registry`,
a process Operator does not run: calling them fails. They exist so a tool
on a computer can drive a world over Erlang distribution. A screen keeps
the handle itself:

```elixir
world = MobRapier.Physics.world_new()   # gravity -9.81 on Y, a ground plane at y = 0
```

The world lives as long as something holds it; when the screen goes away,
so does the world. For a fresh throw, make a new world.

## The API you need

```elixir
alias MobRapier.{Dice, Physics}

w  = Physics.world_new()
id = Physics.add_cuboid(w, x, y, z, hx, hy, hz)        # dynamic box, half-extents; returns a body id
_  = Physics.add_static_cuboid(w, x, y, z, hx, hy, hz) # walls, a table: never moves
:ok = Physics.apply_impulse(w, id, ix, iy, iz)          # a push, N·s
:ok = Physics.apply_torque_impulse(w, id, tx, ty, tz)   # a spin
:ok = Physics.step(w, 1 / 30)                           # advance 1/30 s
Physics.transforms(w)   # [{id, {x, y, z}, {qx, qy, qz, qw}}] for every body, statics too
Physics.body_states(w)  # [%Physics.BodyState{id, pos, quat, speed, ang_speed, sleeping, ...}]
Dice.face_up_d6(quat)   # 1..6 for a settled d6; face_up_d12/1, face_up_d20/1 likewise
```

Body ids are integers in the order you added bodies (statics count). The
ground plane `world_new/0` adds is not a body.

**At rest**: a body is settled when its `BodyState.sleeping` is `true`
(Rapier's own rest flag, set after a short stillness). Read the face then,
and stop the timer once everything sleeps.

**Mass and impulses**: density is 1000 kg/m³ (plastic), so a die with
half-extent `0.03` (a 6 cm cube) weighs about 0.216 kg. A fair throw of
such a die, measured on a phone (60 throws: every face 6 to 15 times,
asleep about a second after release, inside 0.25 m of where it started):
linear impulse `rnd(0.3)` on X and Z and `0.3` up, torque impulse
`rnd(0.01)` on each axis, where `rnd(s) = (:rand.uniform() - 0.5) * s`.
Less spin and it lands on the face it started with (a die added with
`add_cuboid` starts with +Y, the 1, up); much more and it skids and
spins instead of tumbling.

## Bundled models

Operator ships these glTF models; name them in a `Model` and they load
(they live in the app's data dir, set as `mob_scene3d`'s asset root):

| asset | what | scale |
|---|---|---|
| `d6.glb` | a white d6 with black pips, half-extent 1.0; +Y=1, −Y=6, +X=2, −X=5, +Z=3, −Z=4 (matches `Dice.face_up_d6/1`) | scale it by your physics half-extent, e.g. `{0.03, 0.03, 0.03}` |
| `d12.glb`, `d20.glb` | numbered d12 / d20 from the same generator (faces match `face_up_d12/1`, `face_up_d20/1`; their colliders are `add_convex_hull` with `Dice.dodecahedron_vertices/0` / `icosahedron_vertices/0`) | start like the d6 and check the size with `front_screenshot` |
| `table.glb` | a flat wooden tabletop, 3 m square, at y = 0 (the ground plane's height) | as is, at the origin |

There are no primitive shapes (no built-in cube or sphere mesh): a body
needs a `.glb`. A model you download (`Req`) and save in your workspace
works by its absolute path (`Operator.Core.Files.expand/1`).

## The scene

```elixir
alias Mob.Scene3d.IR
alias Mob.Scene3d.IR.{Camera, Entity, Light, Model, Transform}

IR.new([
  %Entity{id: "camera",
          transform: Transform.from_euler({-40.0, 0.0, 0.0}, position: {0.0, 0.9, 0.55}),
          data: %Camera{fov_y: 55.0, near: 0.02, far: 20.0}},
  %Entity{id: "sun", transform: Transform.from_euler({-55.0, 25.0, 0.0}),
          data: %Light{type: :directional, intensity: 100_000.0}},
  %Entity{id: "table", transform: %Transform{}, data: %Model{asset: "table.glb"}},
  %Entity{id: "die1",
          transform: %Transform{position: pos, rotation: rot, scale: {0.03, 0.03, 0.03}},
          data: %Model{asset: "d6.glb"}}
])
```

- Entity ids are strings, unique in the scene. Exactly one camera; it
  looks down its local −Z, so tilt it down with a negative X rotation.
- The viewport: `Mob.Scene3d.viewport(id: :dice, ir: @scene, width: 340,
  height: 420)`, an atom `id` unique on the screen, sizes in dp. Put it in
  a `~MOB` template as `{Mob.Scene3d.viewport(...)}` or as a child node map.
  `background: 0xFF102030` sets the clear colour.
- Each render diffs the new scene against what the viewport shows and sends
  only the changes, so rebuilding the whole IR every tick is fine.
- `pickable: true` on a model and `on_pick: :picked` on the viewport send
  `{:picked, entity_id}` to the screen when it is tapped.

## A complete screen: drop one die, read its face

```elixir
defmodule Operator.Dyn.DieDropScreen do
  use Mob.Screen

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Model, Transform}
  alias MobRapier.{Dice, Physics}

  @tick_ms 33
  @half 0.03

  def mount(_params, _session, socket), do: {:ok, throw_die(socket)}

  def render(assigns) do
    ~MOB"""
    <Column fill_width={true} fill_height={true} background={:background} padding={16}>
      <Spacer size={40} />
      <Text text={@status} text_size={:lg} />
      {Mob.Scene3d.viewport(id: :view, ir: @scene, width: 340, height: 420)}
      <Button text="Roll" on_tap={{self(), :roll}} />
    </Column>
    """
  end

  def handle_info({:tick, ref}, %{assigns: %{tick: ref}} = socket) do
    w = socket.assigns.world
    :ok = Physics.step(w, @tick_ms / 1000)
    [%{pos: pos, quat: rot, sleeping: asleep}] =
      Enum.filter(Physics.body_states(w), &(&1.id == socket.assigns.die))

    socket = Mob.Socket.assign(socket, scene: scene(pos, rot))

    if asleep do
      {:noreply, Mob.Socket.assign(socket, status: "Face up: #{Dice.face_up_d6(rot)}", tick: nil)}
    else
      {:noreply, schedule(socket)}
    end
  end

  def handle_info({:tap, :roll}, socket), do: {:noreply, throw_die(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp throw_die(socket) do
    w = Physics.world_new()
    die = Physics.add_cuboid(w, 0.0, 0.3, 0.0, @half, @half, @half)
    :ok = Physics.apply_impulse(w, die, rnd(0.3), 0.3, rnd(0.3))
    :ok = Physics.apply_torque_impulse(w, die, rnd(0.01), rnd(0.01), rnd(0.01))

    socket
    |> Mob.Socket.assign(world: w, die: die, status: "Rolling...",
         scene: scene({0.0, 0.3, 0.0}, {0.0, 0.0, 0.0, 1.0}))
    |> schedule()
  end

  # A new ref per tick: a stale tick (from before a re-roll) is ignored.
  defp schedule(socket) do
    ref = make_ref()
    Process.send_after(self(), {:tick, ref}, @tick_ms)
    Mob.Socket.assign(socket, tick: ref)
  end

  defp rnd(span), do: (:rand.uniform() - 0.5) * span

  defp scene(pos, rot) do
    IR.new([
      %Entity{id: "camera",
              transform: Transform.from_euler({-40.0, 0.0, 0.0}, position: {0.0, 0.6, 0.45}),
              data: %Camera{fov_y: 55.0, near: 0.02, far: 20.0}},
      %Entity{id: "sun", transform: Transform.from_euler({-55.0, 25.0, 0.0}),
              data: %Light{type: :directional, intensity: 100_000.0}},
      %Entity{id: "table", transform: %Transform{}, data: %Model{asset: "table.glb"}},
      %Entity{id: "die",
              transform: %Transform{position: pos, rotation: rot, scale: {@half, @half, @half}},
              data: %Model{asset: "d6.glb"}}
    ])
  end
end
```

For walls, add static cuboids around the table (half-size 0.3 m) so a
hard throw stays in view: `Physics.add_static_cuboid(w, 0.3, 0.05, 0.0,
0.02, 0.05, 0.3)` and the three others.

## Checking it on the phone

After the generation is active, `front_open` it and `front_screenshot` it:
the screenshot shows the 3D view. Rendering is the GPU's job; stepping the
world 30 times a second is cheap for a few bodies, but stop the timer when
nothing moves.
