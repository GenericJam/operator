defmodule Operator.Core.Dyn do
  @moduledoc """
  The Dyn layer: code the agent writes on the phone (docs/DESIGN.md §2).
  The Core changes it only through this module, one generation at a time:

      stage_put/3 ... ──► propose/2 ──► activate/3 ──► probation ──► proven
       (staging copy)     check,         (approval)     │
                          compile G<n>,                 └─► reverted (crashes,
                          selftest                           failed launch, by hand)

  1. **Stage**: edits go to a staging copy of the current generation's
     sources (`stage_reset/1`, `stage_put/3`, `stage_delete/2`).
  2. **Propose** (`propose/2`): static check (`Operator.Core.Dyn.Check`),
     compile into `Operator.Dyn.G<n>.*` next to the running generation
     (`Operator.Core.Dyn.Compiler`), selftest each module in a contained
     process (`Operator.Core.Dyn.Selftest`). Nothing live changes: the
     result is a proposal (generation, diff, rationale, test results) or a
     rejection saying which step refused and why.
  3. **Activate** (`activate/3`) with a token from the approval seam
     (`request_approval/2`, `Operator.Core.Dyn.Approval`).
  4. **Probation, revert, safe mode**: `Operator.Core.Dyn.Keeper`.

  Generations live on disk (`Operator.Core.Dyn.Store`); the registry maps
  logical names (`{:tool, "weather"}`, `{:screen, "Notes"}`) to the current
  generation's modules (`Operator.Core.Dyn.Registry`); the loop sees Dyn
  tools through `Operator.Core.ToolRegistry`.

  Every function takes the Keeper (its registered name, which is also the
  registry table's) last, defaulting to the app's.
  """

  alias Mob.Router.Hooks
  alias Operator.Core.Dyn.Approval
  alias Operator.Core.Dyn.Check
  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Diff
  alias Operator.Core.Dyn.Generation
  alias Operator.Core.Dyn.Keeper
  alias Operator.Core.Dyn.Registry
  alias Operator.Core.Dyn.Selftest
  alias Operator.Core.Dyn.Store
  alias Operator.Core.ToolRegistry

  @keeper Keeper
  @log_keys [:type, :at, :gen, :module, :kind, :reason, :status, :from, :to, :crashes]

  @type proposal :: %{
          n: pos_integer(),
          parent: non_neg_integer(),
          rationale: String.t(),
          diff: String.t(),
          modules: [Generation.module_entry()],
          selftests: [Generation.selftest()],
          compile_ms: non_neg_integer(),
          warnings: [String.t()]
        }
  @type rejection :: %{
          n: pos_integer() | nil,
          stage: :check | :compile | :selftest | :names | :superseded,
          reason: String.t(),
          violations: [Check.violation()],
          selftests: [Generation.selftest()]
        }

  # ── launch ──

  @doc """
  The Dyn step of `Operator.Boot`: loads the current generation (or decides
  on boot probation / safe mode, see `Operator.Core.Dyn.Keeper`) and has the
  first rendered frame start the clock to "stable".
  """
  @spec boot() :: Keeper.boot_report()
  def boot do
    report = Keeper.boot(@keeper)
    :ok = Hooks.register(:after_first_render, {Keeper, :first_render, [@keeper]})
    report
  end

  # ── staging ──

  @spec staged(atom()) :: %{String.t() => String.t()}
  def staged(keeper \\ @keeper), do: with_dir(keeper, %{}, &Store.staged/1)

  @doc "Resets staging to the current generation's sources."
  @spec stage_reset(atom()) :: :ok | {:error, :not_running}
  def stage_reset(keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper),
         do: Store.reset_staging(dir, Store.sources(dir, status(keeper).generation))
  end

  @doc "Writes `source` to `path` (relative, `.ex`) in staging."
  @spec stage_put(String.t(), String.t(), atom()) :: :ok | {:error, :bad_path | :not_running}
  def stage_put(path, source, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper), do: Store.stage_put(dir, path, source)
  end

  @spec stage_delete(String.t(), atom()) :: :ok | {:error, :bad_path | :not_running}
  def stage_delete(path, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper), do: Store.stage_delete(dir, path)
  end

  # ── proposals ──

  @doc """
  Turns the staged sources into a candidate generation without activating
  it. `{:error, rejection}` names the step that refused (`:check`,
  `:compile`, `:selftest`, `:names`) and why; a rejected generation's
  modules are unloaded and the current one is untouched.
  """
  @spec propose(String.t(), atom()) ::
          {:ok, proposal()}
          | {:error, rejection() | :no_changes | :rationale_required | :not_running}
  def propose(rationale, keeper \\ @keeper) do
    with {:ok, config} <- Registry.config(keeper),
         {:ok, rationale} <- rationale(rationale) do
      parent = status(keeper).generation
      base = Store.sources(config.dir, parent)
      staged = Store.staged(config.dir)

      if staged == base,
        do: {:error, :no_changes},
        else: check(config, keeper, %{parent: parent, rationale: rationale}, base, staged)
    end
  end

  defp check(config, keeper, info, base, staged) do
    case Check.run(staged) do
      {:ok, parsed} ->
        info = Map.put(info, :n, Store.allocate(config.dir))
        build(config, keeper, info, base, staged, parsed)

      {:error, violations} ->
        {:error, rejection(nil, :check, Check.format(violations), violations: violations)}
    end
  end

  defp rationale(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :rationale_required}
      text -> {:ok, text}
    end
  end

  defp build(config, keeper, %{n: n} = info, base, staged, parsed) do
    dir = config.dir

    gen = %Generation{
      n: n,
      parent: info.parent,
      created_at: Generation.now(),
      rationale: info.rationale,
      status: :building,
      files: staged |> Map.keys() |> Enum.sort(),
      runtime: Compiler.runtime()
    }

    Store.put_sources(dir, n, staged)
    :ok = Store.put_generation(dir, gen)
    opts = Keyword.put(config.build, :src_dir, Store.src_dir(dir, n))

    with {:ok, build} <- step(Compiler.compile(parsed, n, opts)),
         :ok <- step(Check.beam(build.modules, n)),
         mods = Enum.map(build.modules, &elem(&1, 0)),
         {:ok, tests} <- step(Selftest.run(mods, opts)),
         {:ok, entries} <- names(build.modules, tests) do
      diff = Diff.unified(base, staged)

      gen = %{
        gen
        | status: :candidate,
          modules: entries,
          selftests: Enum.map(tests, &Map.delete(&1, :name)),
          compile_ms: build.compile_ms,
          warnings: build.warnings
      }

      Store.put_beams(dir, n, build.modules)
      Store.put_diff(dir, n, diff)
      :ok = Store.put_generation(dir, gen)

      case Keeper.candidate(keeper, gen, mods) do
        :ok ->
          {:ok,
           %{
             n: n,
             parent: gen.parent,
             rationale: gen.rationale,
             diff: diff,
             modules: entries,
             selftests: gen.selftests,
             compile_ms: build.compile_ms,
             warnings: build.warnings
           }}

        {:error, :superseded} ->
          {:error, rejection(n, :superseded, "a newer proposal replaced it")}
      end
    else
      {:error, stage, reason, extra} ->
        Compiler.purge(Compiler.loaded(n))
        tests = Keyword.get(extra, :selftests, [])

        _ =
          Store.put_generation(dir, %{
            gen
            | status: :rejected,
              reason: "#{stage}: #{reason}",
              selftests: Enum.map(tests, &Map.delete(&1, :name))
          })

        {:error, rejection(n, stage, reason, extra)}
    end
  end

  defp step({:ok, _} = ok), do: ok
  defp step(:ok), do: :ok
  defp step({:error, {:compile, text}}), do: {:error, :compile, text, []}

  defp step({:error, [%{file: _, message: _} | _] = violations}),
    do: {:error, :check, Check.format(violations), violations: violations}

  defp step({:error, [%{ok: _} | _] = tests}) do
    failed = for %{ok: false} = t <- tests, do: "#{t.module}: #{t.detail}"
    {:error, :selftest, Enum.join(failed, "\n"), selftests: tests}
  end

  # Registry names: a tool's own name (unique, not a Core tool's), else the
  # module name below Operator.Dyn.
  defp names(modules, tests) do
    by_module = Map.new(tests, &{&1.module, &1})
    core = MapSet.new(ToolRegistry.core_tools(), & &1.name())

    entries =
      for {mod, bin} <- modules do
        logical = Compiler.logical(mod)
        test = by_module[logical]
        "Operator.Dyn." <> short = logical

        %{
          module: logical,
          versioned: inspect(mod),
          kind: test.kind,
          name: if(test.kind == :tool, do: test.name, else: short),
          sha256: Compiler.sha256(bin)
        }
      end

    tools = for %{kind: :tool, name: name} <- entries, do: name
    dupes = Enum.uniq(tools -- Enum.uniq(tools))
    clashes = Enum.filter(tools, &MapSet.member?(core, &1))

    cond do
      dupes != [] -> {:error, :names, "two tools are named #{Enum.join(dupes, ", ")}", []}
      clashes != [] -> {:error, :names, "#{Enum.join(clashes, ", ")} is a Core tool's name", []}
      true -> {:ok, entries}
    end
  end

  defp rejection(n, stage, reason, extra \\ []) do
    %{
      n: n,
      stage: stage,
      reason: reason,
      violations: Keyword.get(extra, :violations, []),
      selftests: Keyword.get(extra, :selftests, [])
    }
  end

  # ── approval, activation, revert ──

  @doc "Asks the configured approval (biometric in the app) for a token for `subject`."
  @spec request_approval(Approval.subject(), atom()) :: {:ok, Approval.token()} | {:error, term()}
  def request_approval(subject, keeper \\ @keeper) do
    with {:ok, %{approval: approval}} <- Registry.config(keeper), do: approval.request(subject)
  end

  @doc "Activates candidate generation `n` (it goes on probation). Needs an approval token."
  @spec activate(pos_integer(), Approval.token(), atom()) ::
          {:ok, Generation.t()} | {:error, term()}
  def activate(n, token, keeper \\ @keeper), do: Keeper.activate(keeper, n, token)

  @doc "Makes generation `n` (one that was active once, or 0) current. Needs an approval token."
  @spec revert_to(non_neg_integer(), Approval.token(), atom()) ::
          {:ok, Generation.t()} | {:error, term()}
  def revert_to(n, token, keeper \\ @keeper), do: Keeper.revert_to(keeper, n, token)

  # ── state ──

  @doc "The current generation, its status, its parent, the mode and the pending candidate."
  @spec status(atom()) :: map()
  def status(keeper \\ @keeper) do
    if GenServer.whereis(keeper),
      do: Keeper.status(keeper),
      else: %{generation: 0, status: :proven, parent: nil, mode: :off, pending: nil}
  end

  @doc "Did this launch start in safe mode (no Dyn module loaded)?"
  @spec safe_mode?(atom()) :: boolean()
  def safe_mode?(keeper \\ @keeper), do: Registry.mode(keeper) == :safe

  @doc "Every generation, newest first, generation 0 last."
  @spec generations(atom()) :: [Generation.t()]
  def generations(keeper \\ @keeper), do: with_dir(keeper, [], &Store.generations/1)

  @spec generation(non_neg_integer(), atom()) :: {:ok, Generation.t()} | {:error, term()}
  def generation(n, keeper \\ @keeper),
    do: with_dir(keeper, {:error, :not_running}, &Store.generation(&1, n))

  @doc "Generation `n`'s unified diff against its parent."
  @spec diff(non_neg_integer(), atom()) :: String.t()
  def diff(n, keeper \\ @keeper), do: with_dir(keeper, "", &Store.diff(&1, n))

  @doc """
  The last `limit` reports (crashes, reverts, safe mode, load failures),
  oldest first. Values are as stored (strings for atoms).
  """
  @spec log(pos_integer(), atom()) :: [map()]
  def log(limit \\ 50, keeper \\ @keeper) do
    with_dir(keeper, [], fn dir -> Enum.map(Store.log(dir, limit), &log_entry/1) end)
  end

  defp log_entry(entry) do
    for key <- @log_keys, Map.has_key?(entry, Atom.to_string(key)), into: %{} do
      {key, entry[Atom.to_string(key)]}
    end
  end

  @doc "`{:operator_dyn, event}` for every crash, revert, activation, proof, candidate, safe mode."
  @spec subscribe(atom()) :: :ok
  def subscribe(keeper \\ @keeper) do
    if GenServer.whereis(keeper), do: Keeper.subscribe(keeper), else: :ok
  end

  # ── the registry ──

  @spec lookup(Registry.key(), atom()) :: {:ok, module()} | :error
  def lookup(key, keeper \\ @keeper), do: Registry.lookup(key, keeper)

  @doc "The current generation's tools, `[{name, module}]`."
  @spec tools(atom()) :: [{String.t(), module()}]
  def tools(keeper \\ @keeper), do: Registry.all(:tool, keeper)

  @doc "The current generation's screens, `[{name, module}]`."
  @spec screens(atom()) :: [{String.t(), module()}]
  def screens(keeper \\ @keeper), do: Registry.all(:screen, keeper)

  # ── containment ──

  @doc """
  Has the app's Keeper watch `pid` if `module` is Dyn code, so its crash
  counts against the generation (`Operator.Core.ToolRunner` calls this for
  every tool call). A no-op for Core modules.
  """
  @spec watch(pid(), module()) :: :ok
  def watch(pid, module) do
    if dyn_module?(module), do: Keeper.watch(@keeper, pid, module), else: :ok
  end

  @spec dyn_module?(module()) :: boolean()
  def dyn_module?(module), do: Compiler.generation_of(module) != nil

  defp with_dir(keeper, default, fun) do
    case Registry.config(keeper) do
      {:ok, %{dir: dir}} -> fun.(dir)
      {:error, :not_running} -> default
    end
  end
end
