defmodule Operator.LLMCatalog do
  @moduledoc """
  Gives llm_db (the model catalog req_llm resolves models through) a
  snapshot that works on the phone.

  llm_db reads `priv/llm_db/snapshot.json` (10 MB, 230 providers) at
  runtime, but deps' priv/ isn't shipped to the device and
  `Application.app_dir/2` doesn't resolve there. `compile_embed: true` works
  but costs a 12.9 MB beam and a 2.4-20 s first lookup on a 1-scheduler
  emulator BEAM (docs/SPIKE.md). Operator only talks to OpenRouter, so this
  module trims the packaged snapshot to the `openrouter` provider at compile
  time (1.1 MB, its own snapshot_id so the strict integrity check still
  holds), writes it to the app data dir at boot, and points
  `config :llm_db, :snapshot_path` at it before the first lookup.
  """

  @source Path.expand(Path.join([__DIR__, "../..", "deps/llm_db/priv/llm_db/snapshot.json"]))
  @external_resource @source
  @providers ["openrouter"]

  @json (
          snapshot = @source |> File.read!() |> Jason.decode!()
          snapshot = Map.update!(snapshot, "providers", &Map.take(&1, @providers))
          snapshot = Map.put(snapshot, "snapshot_id", LLMDB.Snapshot.snapshot_id(snapshot))
          LLMDB.Snapshot.encode(snapshot)
        )

  @spec install!() :: :ok
  def install! do
    path = Path.join(Operator.Paths.data_dir(), "llm_db_snapshot.json")
    File.write!(path, @json)
    Application.put_env(:llm_db, :snapshot_path, path)
  end
end
