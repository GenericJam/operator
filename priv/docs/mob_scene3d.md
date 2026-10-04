# mob_scene3d

Declarative 3D scenes for [Mob](https://mobframework.com) apps. One scene
description, rendered identically on iOS and Android through a shared
renderer — [Filament](https://github.com/google/filament) — with thin
per-platform shims for surface, vsync, and input.

**Status: working on both platforms.** Scenes render on iOS (Metal) and
Android (GLES/Vulkan) from one description: glTF models, PBR material
overrides, lights, camera, image-based lighting, skeletal animation
playback, ray picking, and GPU pixel readback. [Chopaat][chopaat] is the
driving consumer — a board game whose board, pawns and cowrie shells are
all `.glb` driven from Elixir.

What is *not* there yet: textures assignable at runtime (they come baked
into the glTF), procedural geometry, and custom shaders. See
[PLAN.md](PLAN.md) for what to add and in what order.

Conventions live in [AGENTS.md](AGENTS.md); work is tracked in beads
(`bd list`).

[chopaat]: https://github.com/GenericJam/chopaat

## Why this shape

The tempting design — wrap SceneKit on iOS and Filament/SceneView on
Android behind one API — fails on semantics: scene-graph shape, material
and lighting models, coordinate handedness, and animation systems all
diverge, and SceneKit is a sunset API. Separate per-platform plugins just
relocate that problem to every app author.

Instead the compat layer is *bought, not built*: Filament runs natively on
both platforms (Metal backend on iOS, GLES/Vulkan on Android, shipped as
prebuilt AAR and xcframework). Embedding it on both sides gives one
scene-graph semantics, one PBR material model, one asset pipeline, one
animation story — identical output on both platforms. Per-platform code
shrinks to plumbing:

| Shared (the plugin)                | Per-platform shims                     |
|------------------------------------|----------------------------------------|
| Scene IR (Elixir data)              | Surface: CAMetalLayer / SurfaceView    |
| IR → Filament applier (C++/NIF)     | Vsync: CADisplayLink / Choreographer   |
| glTF asset loading (gltfio)         | Touch input capture                    |
| Materials, lights, camera, anim     | Plugin/driver-tab registration         |
| Picking + introspection             | Lifecycle (background/resize)          |

## Architecture sketch

The BEAM holds the scene as **data** — a scene tree in assigns, like Mob's
UI trees — and diffs/patches it over the NIF wire. The Elixir side never
talks to Metal or GLES; it talks to one scene IR, and Filament makes that
IR mean the same thing everywhere.

The scene is a list of entities built in plain Elixir and handed to a
viewport component, which diffs it against the last **committed** scene and
ships only the delta over the NIF wire:

```elixir
alias Mob.Scene3d.IR
alias Mob.Scene3d.IR.{Camera, Entity, Light, Material, Model, Transform}

defp scene(assigns) do
  IR.new([
    %Entity{id: "camera", transform: %Transform{position: {0.0, 1.2, 0.9}},
            data: %Camera{fov_y: 45.0}},
    %Entity{id: "sun", data: %Light{type: :directional, intensity: 100_000}},
    %Entity{id: "env", data: %Environment{ibl: "studio"}},
    %Entity{id: "board", data: %Model{asset: "board.glb"}}
    | for p <- assigns.pieces do
        %Entity{
          id: p.id,
          pickable: true,
          transform: %Transform{position: p.pos, rotation: p.rot},
          data: %Model{asset: "piece.glb", material: %Material{base_color: p.color}}
        }
      end
  ])
end

defp viewport(assigns) do
  Mob.Scene3d.viewport(
    id: :board,
    ir: scene(assigns),
    width: 360,
    height: 400,
    on_pick: :piece_picked
  )
end
```

Diffing against the committed scene — not against the last intent — means
coalesced re-renders never desync from what the native applier actually
holds.

## Agent-first, from day one

Every rendering feature ships with introspection, or it doesn't ship. The
3D equivalents of `Mob.Test.element_frames/1` (shipped — see
`decisions/2026-08-30-pick-introspection.md`):

- `Mob.Scene3d.pick(node, x, y)` → the entity under a point — the same
  native ray pick taps ride, so test picking and runtime picking agree
- `Mob.Scene3d.scene(node)` → the **applied** scene graph as data (world
  transforms from the native TransformManager, asset status — never
  echoed intent)
- `Mob.Scene3d.sample_region(node, {x, y, w, h})` → pixel truth via
  Filament GPU readback (window capture cannot see the surface); same
  stats shape as `Mob.Test.sample_color/2`. Assert dominance/tolerance,
  not exact bytes — the readback is post tone-mapping.
- `Mob.Scene3d.frame_stats(node)` → avg/p95 frame ms, dropped-frame and
  frame counts since last query, entity/renderable counts
- Honest errors — `{:error, {:no_entity_at_point, x, y}}`, never a
  phantom `:ok`; misses are query results, not events
- `Mob.Scene3d.Test` mirrors these for test code (a `Mob.Test`-side alias
  awaits a plugin-extension seam in mob core)

This is a hard requirement, not a nice-to-have: an agent that can query the
scene instead of squinting at screenshots is the whole reason to build 3D
on Mob rather than a game engine with an MCP bolted on.

## Asset formats

**glTF 2.0, binary flavor (`.glb`) — the only model/scene/animation format.**
It is Filament's native ingestion path (`gltfio`) and its PBR material
model matches Filament's exactly; it exports cleanly from Blender et al.
Do not accept FBX, OBJ, or USDZ into the pipeline — convert to glTF at
authoring time (USDZ in particular is an Apple-only pipeline dead end here).

- **Models / scenes / animations:** `.glb` (embedded buffers; single file
  per asset — no loose `.gltf` + sidecar files on device)
- **Textures:** KTX2 with Basis Universal supercompression (GPU-friendly on
  both Metal and GLES/Vulkan; PNG/JPEG inside a `.glb` work but transcode
  at load — fine for prototypes, KTX2 for anything shipping)
- **Image-based lighting:** environments precomputed with Filament's
  `cmgen` into KTX (a prefiltered specular cubemap + spherical-harmonics
  irradiance), shipped in `priv/` and referenced by name
- Asset prep is tooling, not app code: `mix scene3d.assets` wraps the
  conversions and validates against the Khronos validator — see
  [guides/assets.md](guides/assets.md) and
  `decisions/2026-08-30-asset-pipeline.md`

## Roadmap

The core is in: Filament embedded on both platforms, scene IR, NIF wire and
appliers, surface/lifecycle shims, asset pipeline, picking and input,
introspection, camera, lights, environment, material overrides, and glTF
animation playback.

What is next, and the reasoning for the ordering, is in
[PLAN.md](PLAN.md) — briefly:

- **`mob_scene3d-qxb`** — a texture reference on the material override, so
  a surface can be re-skinned from Elixir rather than only from the glTF.
  The one gap that blocks a whole class of app.
- **`mob_scene3d-eih`** — ship primitive `.glb` assets (cube, sphere,
  plane, cylinder) instead of adding geometry ops. No native work.
- **`mob_scene3d-962`** — procedural geometry, deliberately deferred until
  a real consumer needs it; it introduces render-thread resource lifetimes
  that authored assets do not.

Deliberately not planned: a general Filament binding. Filament's app-facing
surface is ~1,100 public methods across 39 core headers, most of it builder
and lifecycle plumbing with no meaning to a scene description — and it is
stateful, thread-affine and resource-owning, which is exactly what should
not cross into BEAM-managed state. The scene IR buys the compatibility
without the binding. PLAN.md has the full argument.

## Known costs, accepted deliberately

- Filament adds a few MB per platform and a **prebuilt-binary link step**
  (AAR / xcframework) to builds that are otherwise source-built — new
  territory for mob's zig/Gradle toolchain — de-risked by the embedding
  spike, recorded in `decisions/2026-08-30-filament-spike.md`.
- Filament's release cadence is its own; pin exact versions in the build
  and record upgrades in the changelog.
