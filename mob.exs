# mob.exs — Mob project configuration: plugin activation, plugin trust,
# styles, and build settings. Commit it — a clone without it activates no
# plugins, so their NIFs are left out of the native build.
#
# Machine-specific overrides (e.g. a local `mob_dir` checkout) go in
# mob.local.exs, which is gitignored and imported at the end of this file.
#
# OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

import Config

config :mob_dev,
  # Path to the mob library repo (native source files for iOS/Android builds).
  mob_dir: Path.join(File.cwd!(), "deps/mob"),

  # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
  elixir_lib:
    System.get_env("MOB_ELIXIR_LIB", :code.lib_dir(:elixir) |> to_string() |> Path.dirname()),
  # App-owned C NIF (c_src/<module>.c): the Keychain / EncryptedSharedPrefs
  # store that holds the provider sign-ins (Operator.SecureStore, Operator.Auth).
  static_nifs: [%{module: :operator_secure_store, archs: [:all]}]

# Activated capability plugins (the packages added in mix.exs). Each contributes
# its native code, permissions, and any demo screens at build time. Drop a name
# here to deactivate a plugin without removing the dep; remove both to drop it
# entirely (the native build shrinks and a clean rebuild prunes its artifacts).
config :mob, :plugins, [
  :mob_background,
  :mob_location,
  :mob_notify,
  :mob_camera,
  :mob_photos,
  :mob_scanner,
  # OTA updates of Operator's own code: pure Elixir, no NIF (config in
  # config/config.exs, Operator.Deliver).
  :mob_deliver
]

# Trust gate for the first-party plugins. Each is signed in CI with the shared
# mob release key; this is that key's public fingerprint. The build refuses an
# ACTIVATED plugin whose signature doesn't verify against a trusted fingerprint
# (tamper protection) — entries for plugins you haven't activated are simply
# unused, so every official plugin is pre-trusted and "just works" the moment
# you add it to deps + :plugins above. For your own/third-party plugins, run
# `mix mob.plugin.trust <name>`, or `config :mob, :acknowledge_unsafe_plugins,
# [...]` for an unsigned prototype.
config :mob, :trusted_plugins, %{
  mob_audio_capture: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_camera: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_location: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_biometric: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_background: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_scanner: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_bluetooth: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_screencast: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_photos: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_notify: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_mishka: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_ash: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_deliver: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}

config :mob_dev, beam_flags: "-S 0:0"

if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")
