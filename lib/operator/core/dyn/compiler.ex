defmodule Operator.Core.Dyn.Compiler do
  @moduledoc """
  Compiles a source set into generation `n` (docs/DESIGN.md §2, step 3) and
  loads, unloads and purges generations' modules.

  **Versioned names.** The agent writes `Operator.Dyn.Foo`; `rewrite/2`
  turns every `Operator.Dyn.*` alias in the AST (aliases, module
  references, `~MOB` templates) into `Operator.Dyn.G<n>.*`, so generation
  `n` loads next to the running one and never over it: loading a new version
  of a module the BEAM runs, then loading again, would kill every process
  still in the old code. `__MODULE__` is the versioned name, as it should be.

  **Containment.** The compile runs in its own process with a timeout and a
  `max_heap_size` (module bodies run at compile time). If it fails, every
  module of generation `n` it loaded is purged: nothing runs them.

  **Screens report to the Keeper.** Each screen module (`use Mob.Screen` and
  a `mount/3`) gets a wrapping `mount/3` that registers the screen process
  with `Operator.Core.Dyn.Keeper.watch/3` before calling the original, so
  the Keeper counts its crashes and knows the generation is in use.

  **Unloading** an old generation (`unload/1`) happens only when no process
  runs its code: no module of it is anywhere on a process's stack or its
  initial call; then `:code.delete/1`, and `:code.soft_purge/1` (which
  refuses while `:erlang.check_process_code/2` finds a process in the old
  code); anything still in it is purged later (`purge_old/1`).
  """

  alias Operator.Core.Dyn.Check
  alias Operator.Core.Dyn.Generation
  alias Operator.Core.Dyn.Keeper
  alias Operator.Core.Dyn.Reuse
  alias Operator.Core.Dyn.Selftest
  alias Operator.Core.Dyn.Store
  alias Operator.Core.Dyn.Trace

  require Logger

  @typedoc """
  A compiled generation: its binaries, how long the compile took, its
  warnings, its compile dependencies (`Operator.Core.Dyn.Reuse`) and the
  files reused from the parent rather than compiled.
  """
  @type build :: %{
          modules: [{module(), binary()}],
          compile_ms: non_neg_integer(),
          warnings: [String.t()],
          deps: Reuse.deps(),
          reused: [String.t()]
        }
  @type failure :: {:check, [Check.violation()]} | {:compile, String.t()}

  # runtime/0, computed once per VM.
  @runtime_key {__MODULE__, :runtime}
  @default_timeout_ms 60_000
  @default_max_heap_mb 256

  @doc """
  Checks `sources` and compiles them into generation `n`. Options:
  `:keeper` (the Keeper screens report to), `:src_dir` (absolute dir the
  sources live in, for file names and diagnostics), `:compile_timeout_ms`,
  `:compile_max_heap_mb`, `:reuse` (`%{n: parent, deps: parent's deps,
  beams: %{"Elixir.Operator.Dyn.G<parent>.X" => binary}, unchanged:
  MapSet of files whose source is the parent's}`: compile incrementally,
  `Operator.Core.Dyn.Reuse`).
  """
  @spec build(%{String.t() => String.t()}, pos_integer(), keyword()) ::
          {:ok, build()} | {:error, failure()}
  def build(sources, n, opts) do
    with {:ok, parsed} <- tag(Check.run(sources), :check),
         {:ok, build} <- compile(parsed, n, opts) do
      case Check.beam(build.modules, n) do
        :ok ->
          {:ok, build}

        {:error, violations} ->
          purge(loaded(n))
          {:error, {:check, violations}}
      end
    end
  end

  @doc "Compiles checked files (`Check.run/1`'s result) into generation `n`."
  @spec compile([{String.t(), Macro.t()}], pos_integer(), keyword()) ::
          {:ok, build()} | {:error, {:compile, String.t()}}
  def compile(parsed, n, opts) do
    if loaded(n) != [],
      do: {:error, {:compile, "generation #{n} is already loaded"}},
      else: parsed |> prepare(n, opts) |> isolated(n, opts)
  end

  # `{rel, file, ast}`: rewritten, screens watched, named after their file.
  defp prepare(parsed, n, opts) do
    keeper = Keyword.get(opts, :keeper, Keeper)
    src_dir = Keyword.get(opts, :src_dir)

    for {rel, ast} <- parsed do
      file = if src_dir, do: Path.join(src_dir, rel), else: rel
      {rel, file, ast |> rewrite(n) |> watch_screens(keeper)}
    end
  end

  @doc "Rewrites `Operator.Dyn.*` to `Operator.Dyn.G<n>.*` throughout `ast`."
  @spec rewrite(Macro.t(), pos_integer()) :: Macro.t()
  def rewrite(ast, n) do
    gen = :"G#{n}"

    Macro.prewalk(ast, fn
      {:__aliases__, meta, [:Operator, :Dyn | rest]} ->
        {:__aliases__, meta, [:Operator, :Dyn, gen | rest]}

      {:__aliases__, meta, [:"Elixir", :Operator, :Dyn | rest]} ->
        {:__aliases__, meta, [:Operator, :Dyn, gen | rest]}

      # Template expressions are code only once the sigil expands.
      {:sigil_MOB, meta, [{:<<>>, bmeta, [template]}, mods]} when is_binary(template) ->
        template = Regex.replace(~r/\bOperator\.Dyn\./, template, "Operator.Dyn.G#{n}.")
        {:sigil_MOB, meta, [{:<<>>, bmeta, [template]}, mods]}

      other ->
        other
    end)
  end

  # ── loading ──

  @doc """
  Loads generation `gen` from its stored binaries (checked against the
  manifest's hashes). Binaries built by another runtime (an app update
  since, `stale?/1`) are rebuilt from the sources and selftested again
  before they load (`rebuild/3`, then `store_rebuild/4`). Modules already
  loaded with the same code are left alone.
  """
  @spec load_generation(Path.t(), Generation.t(), keyword()) ::
          {:ok, [module()], Generation.t()} | {:error, String.t()}
  def load_generation(_root, %Generation{n: 0} = gen, _opts), do: {:ok, [], gen}

  def load_generation(root, %Generation{} = gen, opts) do
    if stale?(gen) do
      with {:ok, build, tests} <- rebuild(root, gen, opts),
           do: store_or_purge(root, gen, build, tests)
    else
      load_stored(root, gen)
    end
  end

  defp store_or_purge(root, gen, build, tests) do
    mods = Enum.map(build.modules, &elem(&1, 0))

    case store_rebuild(root, gen, build, tests) do
      {:ok, gen} ->
        {:ok, mods, gen}

      {:error, _} = error ->
        purge(mods)
        error
    end
  end

  @doc "Were `gen`'s stored binaries built by another runtime (`runtime/0`)?"
  @spec stale?(Generation.t()) :: boolean()
  def stale?(%Generation{n: 0}), do: false
  def stale?(%Generation{runtime: runtime}), do: runtime != runtime()

  defp load_stored(root, gen) do
    beams = Store.beams(root, gen.n)
    want = Map.new(gen.modules, &{&1.versioned, &1.sha256})
    have = Map.new(beams, fn {mod, bin} -> {inspect(mod), sha256(bin)} end)

    with :ok <-
           if(want == have,
             do: :ok,
             else: {:error, "generation #{gen.n}'s binaries don't match its manifest"}
           ),
         :ok <- load(beams),
         do: {:ok, Enum.map(beams, &elem(&1, 0)), gen}
  end

  @doc """
  Rebuilds generation `gen` from its stored sources for this runtime and
  selftests it: its modules are loaded, nothing is stored (that's
  `store_rebuild/4`), and a failure leaves none of them loaded. Touches
  only the code server, so it can run outside the Keeper (it does at
  launch: `Operator.Core.Dyn.Keeper`).
  """
  @spec rebuild(Path.t(), Generation.t(), keyword()) ::
          {:ok, build(), [Generation.selftest()]} | {:error, String.t()}
  def rebuild(root, gen, opts) do
    Logger.info(
      "[dyn] rebuilding generation #{gen.n} for #{runtime()} (built for #{gen.runtime})"
    )

    src_dir = Store.src_dir(root, gen.n)

    case build(Store.sources(root, gen.n), gen.n, Keyword.put(opts, :src_dir, src_dir)) do
      {:ok, build} ->
        selftested(gen, build, opts)

      {:error, {_stage, detail}} ->
        {:error, "rebuilding generation #{gen.n} failed: #{failure_text(detail)}"}
    end
  end

  defp selftested(gen, build, opts) do
    mods = Enum.map(build.modules, &elem(&1, 0))

    case Selftest.run(mods, opts) do
      {:ok, tests} ->
        {:ok, build, tests}

      {:error, tests} ->
        purge(mods)
        failed = for %{ok: false} = t <- tests, do: "#{t.module}: #{t.detail}"

        {:error,
         "generation #{gen.n} failed its selftests after a rebuild for #{runtime()}: " <>
           Enum.join(failed, "; ")}
    end
  end

  @doc """
  Stores `rebuild/3`'s binaries and selftest results for `gen`: the
  manifest gets the new hashes and this runtime, and a proven generation
  goes back on probation (its code is new). The caller unloads the modules
  on an error.
  """
  @spec store_rebuild(Path.t(), Generation.t(), build(), [Generation.selftest()]) ::
          {:ok, Generation.t()} | {:error, String.t()}
  def store_rebuild(root, gen, %{modules: beams} = build, tests) do
    hashes = Map.new(beams, fn {mod, bin} -> {inspect(mod), sha256(bin)} end)

    if Enum.sort(Map.keys(hashes)) == Enum.sort(Enum.map(gen.modules, & &1.versioned)) do
      Store.put_beams(root, gen.n, beams)
      Store.put_deps(root, gen.n, build.deps)

      gen = %{
        unprove(gen)
        | modules: Enum.map(gen.modules, &%{&1 | sha256: hashes[&1.versioned]}),
          selftests: Enum.map(tests, &Map.delete(&1, :name)),
          runtime: runtime()
      }

      :ok = Store.put_generation(root, gen)
      {:ok, gen}
    else
      {:error, "rebuilding generation #{gen.n} produced different modules"}
    end
  end

  defp unprove(%Generation{status: :proven} = gen),
    do: %{gen | status: :probation, quiet: false, restarted: false, proven_at: nil}

  defp unprove(gen), do: gen

  @doc "Loads binaries; one already loaded with identical code is skipped."
  @spec load([{module(), binary()}]) :: :ok | {:error, String.t()}
  def load(beams) do
    result =
      Enum.reduce_while(beams, {:ok, []}, fn {mod, bin}, {:ok, done} ->
        case load_one(mod, bin) do
          :loaded -> {:cont, {:ok, [mod | done]}}
          :same -> {:cont, {:ok, done}}
          {:error, message} -> {:halt, {:error, message, done}}
        end
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, message, done} ->
        purge(done)
        {:error, message}
    end
  end

  defp load_one(mod, bin) do
    {:ok, {^mod, md5}} = :beam_lib.md5(bin)

    cond do
      :code.is_loaded(mod) == false -> load_binary(mod, bin)
      mod.module_info(:md5) == md5 -> :same
      true -> {:error, "#{inspect(mod)} is loaded with different code"}
    end
  end

  defp load_binary(mod, bin) do
    case :code.load_binary(mod, ~c"#{mod}.beam", bin) do
      {:module, ^mod} -> :loaded
      {:error, reason} -> {:error, "loading #{inspect(mod)}: #{inspect(reason)}"}
    end
  end

  @doc "Fully unloads modules nothing runs (a candidate's): purge, delete, purge."
  @spec purge([module()]) :: :ok
  def purge(mods) do
    Enum.each(mods, fn mod ->
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)
  end

  @doc """
  Unloads an old generation's modules if no process runs them. `:in_use`
  leaves everything loaded; `{:ok, stuck}` deleted them all and purged all
  but `stuck`, whose old code a process is still executing (retry with
  `purge_old/1`).

  "Runs them" looks at each process's whole stack (its backtrace), not
  only the function it is in: a process sleeping in `Process.sleep/1`,
  called from a Dyn function, returns into that function.
  """
  @spec unload([module()]) :: :in_use | {:ok, [module()]}
  def unload([]), do: {:ok, []}

  def unload(mods) do
    set = MapSet.new(mods)
    # Code addresses print as "('<module>':fun/arity + offset)"; a module
    # name merely held in a variable doesn't count.
    needles = :binary.compile_pattern(Enum.map(mods, &"('#{&1}':"))

    if Enum.any?(Process.list(), &runs?(&1, set, needles)) do
      :in_use
    else
      Enum.each(mods, &:code.delete/1)
      {:ok, purge_old(mods)}
    end
  end

  @doc """
  Purges the old code of `mods` that no process executes
  (`:code.soft_purge/1`, which asks `:erlang.check_process_code/2`);
  returns the rest.
  """
  @spec purge_old([module()]) :: [module()]
  def purge_old(mods), do: Enum.reject(mods, &:code.soft_purge/1)

  # ── names ──

  @doc "Every loaded module of generation `n`."
  @spec loaded(pos_integer()) :: [module()]
  def loaded(n) do
    prefix = "Elixir.Operator.Dyn.G#{n}."
    for {mod, _} <- :code.all_loaded(), String.starts_with?(Atom.to_string(mod), prefix), do: mod
  end

  @doc "The generation a versioned module belongs to, or nil for any other module."
  @spec generation_of(module()) :: pos_integer() | nil
  def generation_of(mod) when is_atom(mod) do
    with "Elixir.Operator.Dyn.G" <> rest <- Atom.to_string(mod),
         {n, "." <> _} <- Integer.parse(rest) do
      n
    else
      _ -> nil
    end
  end

  @doc ~S|The name the agent wrote: `Operator.Dyn.G3.Notes` → `"Operator.Dyn.Notes"`.|
  @spec logical(module()) :: String.t()
  def logical(mod) do
    name = inspect(mod)

    case Regex.run(~r/\AOperator\.Dyn\.G\d+\.(.+)\z/, name) do
      [_, rest] -> "Operator.Dyn." <> rest
      nil -> name
    end
  end

  @doc """
  Identifies the runtime binaries were built by: OTP, Elixir, the app
  version and the Core's code (`core_digest/0`), fixed for the VM's
  lifetime. A Core release, by cable or over the air (`Operator.Deliver`),
  changes it from the next launch on, so every generation built before is
  rebuilt and selftested against the new Core when it loads.
  """
  @spec runtime() :: String.t()
  def runtime do
    case :persistent_term.get(@runtime_key, nil) do
      nil ->
        runtime =
          "otp-#{System.otp_release()} elixir-#{System.version()} operator-#{app_vsn()} " <>
            "core-#{core_digest()}"

        :persistent_term.put(@runtime_key, runtime)
        runtime

      runtime ->
        runtime
    end
  end

  @doc """
  A digest of the Core's code as this VM runs it: every `Operator.*` module
  except the Dyn generations' (`Operator.Dyn.*`), by the MD5 of its loaded
  code, or of its `.beam` on the code path while it isn't loaded (what
  will load). The modules are the `:operator` application's plus every
  loaded `Operator.*` one (a delivered update can add modules); without
  the application's `.app`, every `Operator.*` module on the code path.
  mob_deliver loads the delivered modules at launch, before the Dyn layer
  boots, so a delivered Core counts with its delivered code.
  """
  @spec core_digest() :: String.t()
  def core_digest do
    modules =
      for module <- Enum.uniq(app_modules() ++ loaded_modules()),
          core?(module),
          {:ok, md5} <- [module_md5(module)],
          do: {module, md5}

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(modules)))
    digest |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end

  defp app_modules do
    _ = Application.load(:operator)

    case Application.spec(:operator, :modules) do
      nil ->
        for {name, _file, _loaded?} <- :code.all_available(),
            :lists.prefix(~c"Elixir.Operator.", name),
            do: List.to_atom(name)

      modules ->
        modules
    end
  end

  defp loaded_modules, do: Enum.map(:code.all_loaded(), &elem(&1, 0))

  defp core?(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.Operator.") and
      not String.starts_with?(name, "Elixir.Operator.Dyn.")
  end

  defp module_md5(module) do
    case {:code.is_loaded(module), :code.which(module)} do
      {{:file, _}, _which} -> {:ok, :erlang.get_module_info(module, :md5)}
      {false, path} when is_list(path) -> beam_md5(path)
      _ -> :error
    end
  end

  defp beam_md5(path) do
    case :beam_lib.md5(path) do
      {:ok, {_module, md5}} -> {:ok, md5}
      {:error, :beam_lib, _reason} -> :error
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(bin), do: :sha256 |> :crypto.hash(bin) |> Base.encode16(case: :lower)

  @spec failure_text(String.t() | [Check.violation()]) :: String.t()
  def failure_text(text) when is_binary(text), do: text
  def failure_text(violations), do: Check.format(violations)

  # ── compile process ──

  defp isolated(files, n, opts) do
    timeout = Keyword.get(opts, :compile_timeout_ms, @default_timeout_ms)
    heap = words(Keyword.get(opts, :compile_max_heap_mb, @default_max_heap_mb))
    parent = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: heap,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        send(parent, {ref, compile_files(files, n, Keyword.get(opts, :reuse))})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        finish(result, n, files, Keyword.get(opts, :reuse))

      {:DOWN, ^mref, :process, ^pid, reason} ->
        purge(loaded(n))
        {:error, {:compile, "the compiler process died: #{Exception.format_exit(reason)}"}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        end

        purge(loaded(n))
        {:error, {:compile, "compiling took longer than #{timeout} ms"}}
    end
  end

  defp compile_files(files, n, reuse) do
    :ok = Trace.install()
    # Debug info is what a later generation plans its reuse from (Reuse) and
    # recompiles from when renaming a binary won't do; it's on by default,
    # but a host's `mix test` turns it off.
    :ok = Code.put_compiler_option(:debug_info, true)

    {us, {result, diagnostics}} =
      :timer.tc(fn -> Code.with_diagnostics(fn -> compile_all(files, n, reuse) end) end)

    {result, div(us, 1000), diagnostics}
  end

  defp compile_all(files, n, nil) do
    with {:ok, modules, deps} <- rounds(files, [], %{}, n), do: {:ok, modules, deps, []}
  end

  # Unchanged files the parent's deps allow (Reuse.plan/2) come from its
  # binaries; the rest compile from source on top of them. A module both
  # reused and compiled (one moved between files) means the plan was wrong:
  # everything compiles from source.
  defp compile_all(files, n, reuse) do
    plan = Reuse.plan(reuse.deps, reuse.unchanged)
    {reused, deps, rest} = Enum.reduce(files, {[], %{}, []}, &reuse_file(&1, &2, plan, reuse, n))

    with {:ok, modules, deps} <- rounds(Enum.reverse(rest), reused, deps, n) do
      if length(Enum.uniq_by(modules, &elem(&1, 0))) == length(modules) do
        {:ok, modules, deps, Map.keys(deps) -- Enum.map(rest, &elem(&1, 0))}
      else
        purge(loaded(n))
        compile_all(files, n, nil)
      end
    end
  end

  defp reuse_file({rel, file, _ast} = f, {reused, deps, rest}, plan, reuse, n) do
    with true <- MapSet.member?(plan, rel),
         %{"modules" => mods} = entry <- reuse.deps["files"][rel],
         {:ok, beams} <- recompile_all(mods, reuse, n, file),
         :ok <- load(beams) do
      {reused ++ beams, Map.put(deps, rel, entry), rest}
    else
      _ -> {reused, deps, [f | rest]}
    end
  end

  defp recompile_all(mods, reuse, n, file) do
    Enum.reduce_while(mods, {:ok, []}, fn "Operator.Dyn." <> name, {:ok, acc} ->
      with {:ok, bin} <- Map.fetch(reuse.beams, "Elixir.Operator.Dyn.G#{reuse.n}.#{name}"),
           {:ok, mod, out} <- Reuse.recompile(bin, reuse.n, n, file) do
        {:cont, {:ok, acc ++ [{mod, out}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  # Files compile one by one; one that fails (say, it uses a struct another
  # file defines) is retried once the others are in, until a round makes no
  # progress. Each file's compile-time needs are traced (Reuse).
  defp rounds(pending, done, deps, n) do
    prefix = "Elixir.Operator.Dyn.G#{n}."

    {ok, failed} =
      Enum.reduce(pending, {[], []}, fn {rel, file, ast} = f, {ok, failed} ->
        try do
          {mods, trace} = Trace.collect(prefix, fn -> Code.compile_quoted(ast, file) end)
          {[{rel, mods, trace} | ok], failed}
        catch
          kind, reason ->
            keep = MapSet.new(done ++ Enum.flat_map(ok, &elem(&1, 1)), &elem(&1, 0))
            purge(Enum.reject(loaded(n), &MapSet.member?(keep, &1)))
            {ok, [{f, Exception.format_banner(kind, reason, __STACKTRACE__)} | failed]}
        end
      end)

    ok = Enum.reverse(ok)
    done = done ++ Enum.flat_map(ok, &elem(&1, 1))

    deps =
      Enum.reduce(ok, deps, fn {rel, mods, trace}, acc ->
        Map.put(acc, rel, needs(mods, trace))
      end)

    cond do
      failed == [] -> {:ok, done, deps}
      ok == [] -> {:error, Enum.reverse(failed)}
      true -> rounds(failed |> Enum.reverse() |> Enum.map(&elem(&1, 0)), done, deps, n)
    end
  end

  # Unknown (nil) unless the tracer saw every module the file compiled to.
  defp needs(mods, trace) do
    defined = MapSet.new(mods, &elem(&1, 0))

    needs =
      if MapSet.equal?(defined, trace.defined),
        do: trace.needs |> Enum.map(&logical/1) |> Enum.sort()

    %{"modules" => defined |> Enum.map(&logical/1) |> Enum.sort(), "needs" => needs}
  end

  defp finish({{:ok, modules, files_deps, reused}, ms, diagnostics}, n, files, reuse) do
    exported = Map.new(modules, fn {mod, _} -> {inspect(mod), mod} end)

    warnings =
      for %{severity: :warning} = d <- diagnostics,
          not resolved?(d.message, exported),
          uniq: true,
          do: diagnostic(d, files)

    # A reused module names what its parent named (by written name); the
    # rest are read from their debug info.
    carried =
      for rel <- reused,
          mod <- files_deps[rel]["modules"],
          into: %{},
          do: {mod, reuse.deps["refs"][mod]}

    refs =
      Map.new(modules, fn {mod, bin} ->
        name = logical(mod)
        {name, Map.get_lazy(carried, name, fn -> Reuse.refs(mod, bin, n) end)}
      end)

    {:ok,
     %{
       modules: modules,
       compile_ms: ms,
       warnings: warnings,
       deps: %{"files" => files_deps, "refs" => refs},
       reused: Enum.sort(reused)
     }}
  end

  defp finish({{:error, failed}, _ms, diagnostics}, n, files, _reuse) do
    purge(loaded(n))
    failed_files = MapSet.new(failed, fn {{_rel, file, _ast}, _} -> file end)

    errors =
      for %{severity: :error, file: file} = d <- diagnostics,
          MapSet.member?(failed_files, file),
          uniq: true,
          do: diagnostic(d, files)

    banners = for {{rel, _file, _ast}, banner} <- failed, do: "#{rel}: #{banner}"
    {:error, {:compile, Enum.join(errors ++ banners, "\n")}}
  end

  # "Mod.fun/1 is undefined" about a module of this generation that a later
  # file defined: true by the end of the compile.
  defp resolved?(message, exported) do
    with [_, mod, fun, arity] <- Regex.run(~r/\A(\S+)\.([^.\s]+)\/(\d+) is undefined/, message),
         {:ok, m} <- Map.fetch(exported, mod) do
      arity = String.to_integer(arity)
      Enum.any?(m.module_info(:exports), fn {f, a} -> a == arity and Atom.to_string(f) == fun end)
    else
      _ -> false
    end
  end

  defp diagnostic(%{message: message} = d, files) do
    rel =
      Enum.find_value(files, inspect(d[:file]), fn {rel, file, _} ->
        if file == d[:file], do: rel
      end)

    case d[:position] do
      {line, _col} -> "#{rel}:#{line}: #{message}"
      line when is_integer(line) and line > 0 -> "#{rel}:#{line}: #{message}"
      _ -> "#{rel}: #{message}"
    end
  end

  # ── screen watch ──

  defp watch_screens(ast, keeper) do
    Macro.prewalk(ast, fn
      {:defmodule, meta, [name, [do: body]]} = node ->
        forms = block(body)

        if screen?(forms) and Enum.any?(forms, &mount?/1),
          do: {:defmodule, meta, [name, [do: {:__block__, [], forms ++ [watch(keeper, forms)]}]]},
          else: node

      other ->
        other
    end)
  end

  defp watch(keeper, forms) do
    impl = if Enum.any?(forms, &match?({:@, _, [{:impl, _, _}]}, &1)), do: quote(do: @impl(true))

    quote do
      defoverridable mount: 3
      unquote(impl)

      def mount(params, session, socket) do
        Keeper.watch(unquote(keeper), self(), __MODULE__)
        super(params, session, socket)
      end
    end
  end

  defp block({:__block__, _, forms}), do: forms
  defp block(form), do: [form]

  defp screen?(forms),
    do: Enum.any?(forms, &match?({:use, _, [{:__aliases__, _, [:Mob, :Screen]} | _]}, &1))

  defp mount?({:def, _, [{:when, _, [{:mount, _, [_, _, _]} | _]} | _]}), do: true
  defp mount?({:def, _, [{:mount, _, [_, _, _]} | _]}), do: true

  defp mount?(_form), do: false

  # ── helpers ──

  defp runs?(pid, set, needles) do
    case Process.info(pid, [:current_function, :initial_call, :dictionary, :backtrace]) do
      [current_function: current, initial_call: initial, dictionary: dict, backtrace: bt] ->
        proc_lib_initial =
          case List.keyfind(dict, :"$initial_call", 0) do
            {_, mfa} -> mfa
            nil -> nil
          end

        :binary.match(bt, needles) != :nomatch or
          Enum.any?([current, initial, proc_lib_initial], fn
            {mod, _fun, _arity} -> MapSet.member?(set, mod)
            _ -> false
          end)

      nil ->
        false
    end
  end

  defp tag({:ok, _} = ok, _stage), do: ok
  defp tag({:error, detail}, stage), do: {:error, {stage, detail}}

  defp words(mb), do: div(mb * 1024 * 1024, :erlang.system_info(:wordsize))

  defp app_vsn do
    case Application.spec(:operator, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
