defmodule Operator.Boot do
  @moduledoc """
  The boot sequence after the BEAM is up, timed step by step so the spike
  can report what the agent stack costs at launch. `timings/0` returns
  `[{step, ms}]` plus the BEAM's own uptime at the end of boot.
  """

  alias Operator.Auth
  alias Operator.Auth.Login
  alias Operator.Core.Dyn
  alias Operator.Core.DynTheme

  require Logger

  @key {__MODULE__, :timings}

  @spec run() :: :ok
  def run do
    steps = [
      # The emulator (and some networks) drop outbound UDP :53, so BEAM's
      # pure DNS returns nxdomain; seed the hosts the BEAM talks to (token
      # endpoints and model APIs) through the platform resolver
      # (Mob.DNS.resolve/1), as muster_app does for its host.
      dns: fn ->
        Mob.DNS.configure_pure_beam()

        for host <- ~w(api.anthropic.com auth.openai.com chatgpt.com),
            do: Mob.DNS.resolve(host)
      end,
      tz_data: fn -> :ok = Operator.TzData.install!() end,
      llm_catalog: fn -> :ok = Operator.LLMCatalog.install!() end,
      certs: fn -> :ok = Operator.Certs.install!() end,
      # Mob doesn't start transitive Applications on device: start the
      # agent stack explicitly (jido_ai pulls jido, jido_signal, req_llm,
      # llm_db, finch, req).
      apps: fn -> {:ok, _} = Application.ensure_all_started(:jido_ai) end,
      jido_instance: fn -> {:ok, _} = Operator.Jido.start_link() end,
      llmdb_first_lookup: fn -> {:ok, _} = ReqLLM.model(Operator.Core.default_model()) end,
      repo: fn ->
        {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
        {:ok, _} = Operator.Repo.start_link()
      end,
      # The provider sign-ins (Operator.Auth, which model calls take their
      # tokens from) and `/login`'s browser flow. Earlier builds kept an API
      # key in the secure store (or, before that, a file); nothing uses it.
      auth: fn ->
        _ = Operator.SecureStore.delete("openrouter_api_key")
        _ = File.rm(Path.join(Operator.Paths.data_dir(), "openrouter.key"))
        {:ok, _} = Auth.start_link()
        {:ok, _} = Login.start_link()
      end,
      # The agent loop, sessions, core tools (resumes the latest session) and
      # the Dyn keeper.
      core: fn -> {:ok, _} = Operator.Core.start_link() end,
      # A delivered Core update's probation ends with the Keeper's stable
      # launch, not at mob_deliver's first frame (Operator.Deliver).
      deliver: fn -> :ok = Operator.Deliver.take_over_probation() end,
      # The current Dyn generation (or boot probation's revert, or safe mode:
      # Core only), see Operator.Core.Dyn.Keeper. A failed launch whose Core
      # update mob_deliver just rolled back doesn't count against it.
      dyn: fn ->
        %{} = Dyn.boot(core_rolled_back: Operator.Deliver.rolled_back_this_launch?())
      end,
      # The theme that generation defines, if any (Operator.Core.DynTheme).
      dyn_theme: fn -> :ok = DynTheme.refresh() end
    ]

    timings =
      for {name, fun} <- steps do
        {us, _} = :timer.tc(fun)
        {name, div(us, 1000)}
      end

    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    all = timings ++ [beam_uptime_at_boot_end: uptime_ms]
    :persistent_term.put(@key, all)
    Logger.info("[boot] #{inspect(all)}")
    :ok
  end

  @spec timings() :: keyword()
  def timings, do: :persistent_term.get(@key, [])
end
