defmodule Operator.MixProject do
  use Mix.Project

  def project do
    [
      app: :operator,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_options: [:debug_info]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mob, "~> 0.9.12"},
      {:mob_dev, "~> 0.7.15", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # The on-phone agent: Jido (agent runtime), Jido.AI (ReAct loop,
      # tool calling) and req_llm (provider clients; Anthropic, OpenAI Codex).
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.3"},
      {:req_llm, "~> 1.26"},
      # zoi 0.18.11 removed Zoi.Types.Default, which jido/jido_ai still use.
      {:zoi, "~> 0.18.10 and < 0.18.11"},
      # Keeps the app running while an agent run is backgrounded (Android
      # foreground service; iOS silent audio session): Operator.Core.KeepAlive.
      {:mob_background, "~> 0.1.2"},
      # Phone tools (Operator.Core.Phone brokers them through the chat screen).
      {:mob_location, "~> 0.1.5"},
      {:mob_notify, "~> 0.2.0"},
      # camera_snap (MobCamera.snap/1: the agent's own headless photo).
      {:mob_camera, "~> 0.1.12"},
      # Photos for the model: thumbnail/2 (scaled, with EXIF), list_media on iOS.
      {:mob_photos, "~> 0.2.0"},
      # Every sensor: barometer, light, proximity, steps, humidity, ... (`sensors`).
      {:mob_sensors, "~> 0.1.0"},
      # Diagnostics → Scan QR: the codes `mix operator.login` and `mix
      # operator.handoff` show on the Mac (Operator.LoginScanScreen).
      {:mob_scanner, "~> 0.1.5"},
      # The rest of the mob toolbox, as Sloppy Joe carries it, for the front
      # (the screens the user and the agent build; PLAN.md step 9). Each
      # permission is asked at first use. Operator's own approval stays on
      # OperatorApproval.kt; mob_biometric is for front screens.
      {:mob_biometric, "~> 0.1.5"},
      {:mob_bluetooth, "~> 0.4.1"},
      {:mob_screencast, "~> 0.1.2"},
      {:mob_video, "~> 0.1.1"},
      {:mob_touch, "~> 0.1.1"},
      {:mob_wake, "~> 0.1.1"},
      {:mob_sms, "~> 0.2.3"},
      {:mob_vision, "~> 0.1.2"},
      {:mob_nfc, "~> 0.1.4"},
      {:mob_midi, "~> 0.1.2"},
      # Android only (iOS has no output-mix capture; its NIF answers
      # :unsupported_on_platform).
      {:mob_audio_capture, "~> 0.1.2"},
      # Declarative 3D scenes (Filament) for front screens.
      {:mob_scene3d, "~> 0.1.3"},
      # Nx on the phone: the Eigen CPU backend (configured at boot by the plugin).
      {:mob_nx_eigen, "~> 0.1.1"},
      # TensorFlow Lite on the GPU/NPU (NNAPI on Android, Core ML on iOS;
      # `mix mob.enable tflite`'s dep; Operator.Core.Tflite picks the delegate).
      {:nx_tflite_mob, "~> 0.0.4"},
      # 3D physics: a Rustler NIF, linked as the :lab_physics static NIF (mob.exs).
      {:mob_rapier, "~> 0.1.0"},
      # Ash resources (front screens declare them; Ash.DataLayer.Ets) and
      # mob_ash's list/detail/create screens for them (MobAsh.navigate/3).
      {:mob_ash, "~> 0.1.2"},
      # Dictation: hold the mic, the phone transcribes offline (whisper.cpp,
      # Operator.ChatScreen). mob_speech is the speech API, mob_whisper its
      # on-device engine (a mob plugin, mob.exs).
      {:mob_speech, "~> 0.1"},
      {:mob_whisper, "~> 0.1"},
      # Over-the-air updates of Operator's own code (docs/DESIGN.md §1, the
      # Core's release path; Operator.Deliver). mob_deliver is the phone side,
      # a mob plugin (mob.exs). mob_deliver_server and Bandit are the Mac side
      # (`mix operator.deliver.*`, `mix operator.publish`): dev/test only, so
      # mob_dev never ships them to the phone.
      {:mob_deliver, "~> 0.3.1"},
      # The default front (PLAN.md step 9): the Mishka Chelekom widget gallery
      # `mix mob.new` generates. mob_mishka supplies its <Mishka…> composite
      # tags (a mob plugin, mob.exs); mob_themes is the style package it uses.
      {:mob_mishka, "~> 0.1.3"},
      {:mob_themes, "~> 0.1.0"},
      {:mob_deliver_server, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.6", only: [:dev, :test], runtime: false},
      # Mozilla CA bundle: Android has no system CA store the BEAM can find
      # (see Operator.Certs).
      {:castore, "~> 1.0"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end
end
