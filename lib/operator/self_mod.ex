defmodule Operator.SelfMod do
  @moduledoc """
  On-device compilation: the app compiles Elixir source into new modules,
  loads them, self-tests them, and persists the source so they come back
  after a restart.

  Layout: `<MOB_DATA_DIR>/selfmod/<name>.ex`. At boot `recompile_all/0`
  compiles every persisted source (timed). A module may define
  `selftest/0` returning `:ok` (or raising); `install/2` refuses to
  persist source whose selftest fails, so a broken module is never written
  where boot would pick it up.

  Spike scope: no versioning or rollback beyond "the source file is the
  module"; see docs/SPIKE.md for the real design.
  """
  require Logger

  @type result :: %{
          modules: [module()],
          compile_us: non_neg_integer(),
          selftest: :ok | :none | {:error, term()}
        }

  @doc "Compiles and loads `source` (not persisted). Returns modules + timing."
  @spec compile(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def compile(source, file \\ "nofile") do
    {us, res} =
      :timer.tc(fn ->
        try do
          {:ok, Code.compile_string(source, file)}
        rescue
          e -> {:error, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 2000)}
        end
      end)

    with {:ok, pairs} <- res do
      mods = Enum.map(pairs, &elem(&1, 0))
      {:ok, %{modules: mods, compile_us: us, selftest: selftest(mods)}}
    end
  end

  @doc "Compile, selftest, and (only if the selftest passes) persist under `name`."
  @spec install(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def install(name, source) do
    true = Regex.match?(~r/\A[a-z0-9_]+\z/, name)

    case compile(source, Path.join(dir(), name <> ".ex")) do
      {:ok, %{selftest: st} = r} when st in [:ok, :none] ->
        File.write!(Path.join(dir(), name <> ".ex"), source)
        {:ok, r}

      {:ok, %{selftest: err, modules: mods}} ->
        Enum.each(mods, &purge/1)
        {:error, {:selftest_failed, err}}

      err ->
        err
    end
  end

  @doc "Recompiles every persisted source. Called from on_start."
  @spec recompile_all() :: [{String.t(), {:ok, result()} | {:error, term()}}]
  def recompile_all do
    for file <- Path.wildcard(Path.join(dir(), "*.ex")) |> Enum.sort() do
      name = Path.basename(file, ".ex")
      res = compile(File.read!(file), file)

      case res do
        {:ok, r} ->
          Logger.info("[selfmod] #{name}: #{inspect(r.modules)} in #{div(r.compile_us, 1000)} ms")

        {:error, e} ->
          Logger.error("[selfmod] #{name} failed to compile: #{inspect(e)}")
      end

      {name, res}
    end
  end

  @doc "Persisted names."
  @spec list() :: [String.t()]
  def list, do: Path.wildcard(Path.join(dir(), "*.ex")) |> Enum.map(&Path.basename(&1, ".ex"))

  @spec remove(String.t()) :: :ok
  def remove(name) do
    _ = File.rm(Path.join(dir(), name <> ".ex"))
    :ok
  end

  @doc "Modules compiled from persisted sources that are Mob screens."
  @spec screens() :: [module()]
  def screens do
    for {mod, _} <- :code.all_loaded(),
        mod |> Atom.to_string() |> String.starts_with?("Elixir.Operator.Dyn."),
        function_exported?(mod, :render, 1),
        do: mod
  end

  defp selftest(mods) do
    case Enum.find(mods, &function_exported?(&1, :selftest, 0)) do
      nil ->
        :none

      mod ->
        try do
          case mod.selftest() do
            :ok -> :ok
            other -> {:error, {:returned, other}}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end

  defp dir do
    d = Path.join(Operator.Paths.data_dir(), "selfmod")
    File.mkdir_p!(d)
    d
  end
end
