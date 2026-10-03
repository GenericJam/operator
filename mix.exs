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
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mob, "~> 0.9.10"},
      {:mob_dev, "~> 0.7.9", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # The on-phone agent: Jido (agent runtime), Jido.AI (ReAct loop,
      # tool calling) and req_llm (provider clients; OpenRouter).
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.3"},
      {:req_llm, "~> 1.26"},
      # zoi 0.18.11 removed Zoi.Types.Default, which jido/jido_ai still use.
      {:zoi, "~> 0.18.10 and < 0.18.11"},
      # Fingerprint/face gate on applying a self-modification.
      {:mob_biometric, "~> 0.1.5"},
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
