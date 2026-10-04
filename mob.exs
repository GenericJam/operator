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
  static_nifs: [%{module: :operator_secure_store, archs: [:all]}],
  # operator:// links (Operator.Links: the QR codes mix operator.handoff,
  # operator.login and operator.deliver.qr make on the Mac, scanned with any app).
  # The native build adds the Android intent filter (MainActivity must stay
  # singleTask) and the iOS URL type; each link arrives as {:link, ...}.
  url_schemes: ["operator"]

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
  # For the front (PLAN.md step 9): the rest of Sloppy Joe's toolbox.
  :mob_biometric,
  :mob_bluetooth,
  :mob_screencast,
  :mob_video,
  :mob_touch,
  :mob_wake,
  # OTA updates of Operator's own code: pure Elixir, no NIF (config in
  # config/config.exs, Operator.Deliver).
  :mob_deliver,
  # Offline dictation (whisper.cpp + the microphone capture), the MobWhisper
  # engine Operator.ChatScreen hands MobSpeech. mob_speech itself isn't
  # activated: its own NIF is the platform recognizer, which Operator doesn't use.
  :mob_whisper,
  # The <Mishka…> composite tags the default front (the widget gallery) uses.
  :mob_mishka
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
  mob_deliver: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_video: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_touch: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_wake: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_whisper: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}

# mob_whisper comes from its git tag until Hex has it (mix.exs), and a git
# checkout carries no signature (CI signs only what it publishes to Hex): until
# then the trust gate is acknowledged for it. Drop this with the switch to Hex.
config :mob, :acknowledge_unsafe_plugins, [:mob_whisper]

# Style packages the front may use (mob_themes, as `mix mob.new` sets up). No
# :default_style: Operator's own theme stays as the Core and Dyn set it.
config :mob, :styles, [:mob_themes]

config :mob_dev, beam_flags: "-S 0:0"

if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")
