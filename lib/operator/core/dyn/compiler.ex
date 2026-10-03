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
  runs its code: nothing has a module of it as its current function or
  initial call, and after `:code.delete/1` no process is in its old code
  (`:erlang.check_process_code/2`); anything still in it is purged later
  (`purge_old/1`).
  """

  alias Operator.Core.Dyn.Check
  alias Operator.Core.Dyn.Generation
  alias Operator.Core.Dyn.Keeper
  alias Operator.Core.Dyn.Store

  require Logger

  @type build :: %{
          modules: [{module(), binary()}],
          compile_ms: non_neg_integer(),
          warnings: [String.t()]
        }
  @type failure :: {:check, [Check.violation()]} | {:compile, String.t()}

  @default_timeout_ms 60_000
  @default_max_heap_mb 256

  @doc """
  Checks `sources` and compiles them into generation `n`. Options:
  `:keeper` (the Keeper screens report to), `:src_dir` (absolute dir the
  sources live in, for file names and diagnostics), `:compile_timeout_ms`,
  `:compile_max_heap_mb`.
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
  since) are rebuilt from the sources first; the manifest records the new
  hashes. Modules already loaded with the same code are left alone.
  """
  @spec load_generation(Path.t(), Generation.t(), keyword()) ::
          {:ok, [module()], Generation.t()} | {:error, String.t()}
  def load_generation(_root, %Generation{n: 0} = gen, _opts), do: {:ok, [], gen}

  def load_generation(root, %Generation{} = gen, opts) do
    if gen.runtime == runtime(),
      do: load_stored(root, gen),
      else: rebuild(root, gen, opts)
  end

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

  defp rebuild(root, gen, opts) do
    Logger.info(
      "[dyn] rebuilding generation #{gen.n} for #{runtime()} (built for #{gen.runtime})"
    )

    src_dir = Store.src_dir(root, gen.n)

    case build(Store.sources(root, gen.n), gen.n, Keyword.put(opts, :src_dir, src_dir)) do
      {:ok, %{modules: beams}} ->
        hashes = Map.new(beams, fn {mod, bin} -> {inspect(mod), sha256(bin)} end)

        if Enum.sort(Map.keys(hashes)) == Enum.sort(Enum.map(gen.modules, & &1.versioned)) do
          Store.put_beams(root, gen.n, beams)
          modules = Enum.map(gen.modules, &%{&1 | sha256: hashes[&1.versioned]})
          gen = %{gen | modules: modules, runtime: runtime()}
          :ok = Store.put_generation(root, gen)
          {:ok, Enum.map(beams, &elem(&1, 0)), gen}
        else
          purge(Enum.map(beams, &elem(&1, 0)))
          {:error, "rebuilding generation #{gen.n} produced different modules"}
        end

      {:error, {_stage, detail}} ->
        {:error, "rebuilding generation #{gen.n} failed: #{failure_text(detail)}"}
    end
  end

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
  """
  @spec unload([module()]) :: :in_use | {:ok, [module()]}
  def unload(mods) do
    set = MapSet.new(mods)

    if Enum.any?(Process.list(), &runs?(&1, set)) do
      :in_use
    else
      Enum.each(mods, &:code.delete/1)
      {:ok, purge_old(mods)}
    end
  end

  @doc "Purges the old code of `mods` no process executes; returns the rest."
  @spec purge_old([module()]) :: [module()]
  def purge_old(mods) do
    pids = Process.list()
    {stuck, free} = Enum.split_with(mods, fn mod -> Enum.any?(pids, &old_code?(&1, mod)) end)
    Enum.each(free, &:code.purge/1)
    stuck
  end

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

  @doc "Identifies the runtime binaries were built by (OTP, Elixir, app version)."
  @spec runtime() :: String.t()
  def runtime,
    do: "otp-#{System.otp_release()} elixir-#{System.version()} operator-#{app_vsn()}"

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

        send(parent, {ref, compile_files(files, n)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        finish(result, n, files)

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

  defp compile_files(files, n) do
    {us, {result, diagnostics}} =
      :timer.tc(fn -> Code.with_diagnostics(fn -> rounds(files, [], n) end) end)

    {result, div(us, 1000), diagnostics}
  end

  # Files compile one by one; one that fails (say, it uses a struct another
  # file defines) is retried once the others are in, until a round makes no
  # progress.
  defp rounds(pending, done, n) do
    {ok, failed} =
      Enum.reduce(pending, {[], []}, fn {_rel, file, ast} = f, {ok, failed} ->
        try do
          {[Code.compile_quoted(ast, file) | ok], failed}
        catch
          kind, reason ->
            keep = MapSet.new(done ++ List.flatten(ok), &elem(&1, 0))
            purge(Enum.reject(loaded(n), &MapSet.member?(keep, &1)))
            {ok, [{f, Exception.format_banner(kind, reason, __STACKTRACE__)} | failed]}
        end
      end)

    done = done ++ (ok |> Enum.reverse() |> List.flatten())

    cond do
      failed == [] -> {:ok, done}
      ok == [] -> {:error, Enum.reverse(failed)}
      true -> rounds(failed |> Enum.reverse() |> Enum.map(&elem(&1, 0)), done, n)
    end
  end

  defp finish({{:ok, modules}, ms, diagnostics}, _n, files) do
    exported = Map.new(modules, fn {mod, _} -> {inspect(mod), mod} end)

    warnings =
      for %{severity: :warning} = d <- diagnostics,
          not resolved?(d.message, exported),
          uniq: true,
          do: diagnostic(d, files)

    {:ok, %{modules: modules, compile_ms: ms, warnings: warnings}}
  end

  defp finish({{:error, failed}, _ms, diagnostics}, n, files) do
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

  defp runs?(pid, set) do
    case Process.info(pid, [:current_function, :initial_call, :dictionary]) do
      [current_function: current, initial_call: initial, dictionary: dict] ->
        proc_lib_initial =
          case List.keyfind(dict, :"$initial_call", 0) do
            {_, mfa} -> mfa
            nil -> nil
          end

        Enum.any?([current, initial, proc_lib_initial], fn
          {mod, _fun, _arity} -> MapSet.member?(set, mod)
          _ -> false
        end)

      nil ->
        false
    end
  end

  defp old_code?(pid, mod), do: :erlang.check_process_code(pid, mod)

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
