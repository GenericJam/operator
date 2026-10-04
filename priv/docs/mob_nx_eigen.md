# mob_nx_eigen

Eigen-backed CPU [Nx](https://github.com/elixir-nx/nx) backend, packaged as a
[mob](https://github.com/GenericJam/mob) plugin.

This is the **always-available baseline** for on-device numerics. Eigen is a
header-only C++ template library (NEON-vectorised on ARM), so it needs no GPU
and runs anywhere mob runs — iOS and Android, any chip. GPU-accelerated
backends (Vulkan, MLX, TFLite) layer on top where a device supports them;
NxEigen is the fallback that always works.

## How it's built

The NIF is a C++ `:cpp_archive` plugin contribution: mob_dev's
`MobDev.Plugin.CppArchive` cross-compiles it to `libnx_eigen.a` per target ABI
and static-links it into the app's single signed native binary (required —
Android `RTLD_LOCAL` hides the BEAM's `enif_*` symbols from a separately-loaded
`.so`, and iOS forbids `dlopen`). It references NxEigen's own NIF source + Fine
headers straight from its deps (`{:dep, …}` tokens) and ships the Eigen-FFT
bridge itself (`c_src/`).

**Eigen headers** are fetched at compile time by the bundled `eigen_headers` Mix
compiler into `eigen-3.4.0/` (gitignored) — the published `nx_eigen` hex package
downloads Eigen in its own Makefile and ships a precompiled `.so`, so a clean
`mix deps.get` has no Eigen for the source cross-compile to reference. Set
`EIGEN_DIR` to a local Eigen 3.4.0 checkout to skip the download.

> **Android ABI:** `cpp_archive` targets arm64/arm32 (+ iOS), **not** the
> `x86_64` Android emulator — build/deploy to an arm device (or drop `x86_64`
> from your app's `abiFilters` + build.zig). Building x86_64 with this plugin
> fails the link with an unresolved `nx_eigen_nif_init`.

Requires a mob_dev with `cpp_archive` + the `ANDROID_HOME`-aware NDK resolution
(≥ the release carrying MOB-89).

## Use

```elixir
# mix.exs
{:mob_nx_eigen, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_nx_eigen]
```

The plugin's `lifecycle.on_start` calls `MobNxEigen.configure/0` at app boot,
which makes `NxEigen.Backend` the global Nx backend (falling back to
`Nx.BinaryBackend` if the NIF can't load).

## Status

Replaces the bespoke `nxeigen` hooks that used to live in mob_dev core
(`mix mob.enable nxeigen`). Device verification on Android/iOS pending.
