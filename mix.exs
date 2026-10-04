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
      {:mob, "~> 0.9.11"},
      {:mob_dev, "~> 0.7.13", only: :dev, runtime: false},
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
      {:mob_location, "~> 0.1.4"},
      {:mob_notify, "~> 0.2.0"},
      {:mob_camera, "~> 0.1.11"},
      {:mob_photos, "~> 0.1.3"},
      # Diagnostics → Scan QR: the codes `mix operator.login` and `mix
      # operator.handoff` show on the Mac (Operator.LoginScanScreen).
      {:mob_scanner, "~> 0.1.5"},
      # Dictation: hold the mic, the phone transcribes offline (whisper.cpp,
      # Operator.ChatScreen). mob_speech is the speech API, mob_whisper its
      # on-device engine (a mob plugin, mob.exs). Git tags until Hex has them
      # (their HEX_API_KEY is pending); then "~> 0.1" and drop the override.
      {:mob_speech, github: "GenericJam/mob_speech", tag: "0.1.0", override: true},
      {:mob_whisper, github: "GenericJam/mob_whisper", tag: "0.1.0"},
      # Over-the-air updates of Operator's own code (docs/DESIGN.md §1, the
      # Core's release path; Operator.Deliver). mob_deliver is the phone side,
      # a mob plugin (mob.exs). mob_deliver_server and Bandit are the Mac side
      # (`mix operator.deliver.*`, `mix operator.publish`): dev/test only, so
      # mob_dev never ships them to the phone.
      {:mob_deliver, "~> 0.3.1"},
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
