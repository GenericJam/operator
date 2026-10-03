import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Operator.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :operator, ecto_repos: [Operator.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Operator.Repo

# llm_db reads priv/llm_db/snapshot.json at runtime by default, but mob_dev
# ships deps' ebins without their priv/, and Application.app_dir/2 does not
# resolve on device. Operator.LLMCatalog embeds an Anthropic + OpenAI trim of
# the snapshot and sets :snapshot_path at boot. (`compile_embed: true` also
# works but embeds all 230 providers: a 12.9 MB beam and a ~19 s first lookup
# on the emulator; it is compile_env, so switching needs
# `mix deps.compile llm_db --force`.)
config :llm_db, compile_embed: false

# req_llm loads a .env file from the CWD at boot by default; there is none
# on the phone, and the model tokens come from the sign-ins (Operator.Auth).
config :req_llm, load_dotenv: false

# The spike agent's model is the :operator alias, resolved when an agent
# starts (Operator.Diag.agent/0).
config :jido_ai,
  model_aliases: %{operator: "anthropic:claude-haiku-4-5"}

# time_zone_info (a jido dependency) reads its data from its priv/ dir by
# default, which isn't shipped to the device. Operator.TzData embeds the file
# and sets :file_system's path at boot.
config :time_zone_info, data_persistence: TimeZoneInfo.DataPersistence.FileSystem
