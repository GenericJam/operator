defmodule Operator.Core.Dyn.Reuse do
  @moduledoc """
  Incremental compiles: a proposal recompiles only the files that changed
  (or depend on a change at compile time) and reuses the rest from its
  parent generation, renamed. On a Moto G 2021 compiling the 67-module
  default front from source takes about 33 s; recompiling all 67 from
  their stored Erlang code takes about 6 s (the Elixir expansion is the
  expensive part), so changing one screen costs about 7 s.

  **What a generation records** (`deps`, stored next to its binaries,
  `Operator.Core.Dyn.Store.deps/2`), by the names the agent wrote
  (`"Operator.Dyn.Notes"`):

    * per file, the modules it defines and the modules it needs at compile
      time (`Operator.Core.Dyn.Trace`), or `nil` when that's unknown;
    * per module, the modules its compiled code names anywhere (calls,
      literals, attributes), from its debug info.

  **Which files are reused** (`plan/2`): an unchanged file whose needs are
  known, none of which is *dirty*. A module is dirty if its file isn't
  reused (changed, deleted, or itself dirty), or if its code names a dirty
  module, directly or through others: a compile-time call into it may
  reach the change. Repeated until nothing changes.

  **Reusing** (`recompile/4`): the parent's binary's Erlang abstract code
  (its debug info) with every `Operator.Dyn.G<parent>.*` atom renamed to
  `Operator.Dyn.G<n>.*`, compiled by the Erlang compiler. A module whose
  code still holds the parent generation's name afterwards (a string built
  at compile time, say) or that doesn't compile is compiled from source
  instead. Generations built by another runtime (a Core update) are never
  reused from: the Keeper rebuilds them whole.
  """

  alias Operator.Core.Dyn.Compiler

  @type deps :: %{String.t() => map()}

  @doc "Empty deps: nothing known, nothing reused."
  @spec empty() :: deps()
  def empty, do: %{"files" => %{}, "refs" => %{}}

  @doc """
  The files of `deps` (the parent's) to reuse, given the files whose
  source is the same as the parent's (`unchanged`).
  """
  @spec plan(deps(), MapSet.t(String.t())) :: MapSet.t(String.t())
  def plan(%{"files" => files, "refs" => refs}, unchanged) do
    candidates =
      for {rel, %{"needs" => needs}} <- files,
          is_list(needs),
          MapSet.member?(unchanged, rel),
          into: MapSet.new(),
          do: rel

    # Every module the parent had; one with no recorded names might name any.
    refs = for {_rel, %{"modules" => mods}} <- files, mod <- mods, into: %{}, do: {mod, refs[mod]}
    settle(files, refs, candidates)
  end

  def plan(_deps, _unchanged), do: MapSet.new()

  defp settle(files, refs, reuse) do
    dirty =
      for {rel, %{"modules" => mods}} <- files,
          not MapSet.member?(reuse, rel),
          mod <- mods,
          into: MapSet.new(),
          do: mod

    reach = reach(refs, dirty)

    kept =
      MapSet.filter(reuse, fn rel ->
        not Enum.any?(files[rel]["needs"], &MapSet.member?(reach, &1))
      end)

    if MapSet.equal?(kept, reuse), do: reuse, else: settle(files, refs, kept)
  end

  # Dirty modules and every module whose code names one, transitively.
  # Unknown names (nil) might be any.
  defp reach(refs, dirty) do
    more =
      for {mod, names} <- refs,
          not MapSet.member?(dirty, mod),
          names_any?(names, dirty),
          into: MapSet.new(),
          do: mod

    if MapSet.size(more) == 0, do: dirty, else: reach(refs, MapSet.union(dirty, more))
  end

  defp names_any?(nil, dirty), do: MapSet.size(dirty) > 0
  defp names_any?(names, dirty), do: Enum.any?(names, &MapSet.member?(dirty, &1))

  @doc """
  Generation `to`'s version of `bin`, a module of generation `from`, for
  source file `file`: `{:ok, module, binary}`, or `:error` when it has to
  be compiled from source.
  """
  @spec recompile(binary(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, module(), binary()} | :error
  def recompile(bin, from, to, file) do
    old = "Elixir.Operator.Dyn.G#{from}."
    new = "Elixir.Operator.Dyn.G#{to}."

    with {:ok, {_mod, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(bin, [:abstract_code]),
         forms = forms |> rename(old, new) |> refile(file),
         false <- mentions?(forms, ~c"Operator.Dyn.G#{from}."),
         {:ok, mod, out} <-
           :compile.forms(forms, [
             :binary,
             :debug_info,
             :return_errors,
             :no_spawn_compiler_process
           ]) do
      {:ok, mod, out}
    else
      _ -> :error
    end
  end

  @doc """
  The modules of generation `n` (by their written names) that `bin`'s code
  names, other than itself; nil when it has no debug info (it might name
  any).
  """
  @spec refs(module(), binary(), pos_integer()) :: [String.t()] | nil
  def refs(mod, bin, n) do
    prefix = "Elixir.Operator.Dyn.G#{n}."

    case :beam_lib.chunks(bin, [:debug_info]) do
      {:ok, {^mod, [debug_info: {:debug_info_v1, _backend, _data} = info]}} ->
        info
        |> atoms(prefix, MapSet.new())
        |> MapSet.delete(mod)
        |> Enum.map(&Compiler.logical/1)
        |> Enum.sort()

      _ ->
        nil
    end
  end

  defp atoms(term, prefix, acc) when is_atom(term) do
    if String.starts_with?(Atom.to_string(term), prefix), do: MapSet.put(acc, term), else: acc
  end

  defp atoms(term, prefix, acc) when is_list(term),
    do: Enum.reduce(term, acc, &atoms(&1, prefix, &2))

  defp atoms(term, prefix, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> atoms(prefix, acc)

  defp atoms(term, prefix, acc) when is_map(term),
    do: Enum.reduce(term, acc, fn {k, v}, acc -> atoms(v, prefix, atoms(k, prefix, acc)) end)

  defp atoms(_term, _prefix, acc), do: acc

  defp rename(term, old, new) when is_atom(term) do
    name = Atom.to_string(term)

    if String.starts_with?(name, old),
      do:
        String.to_atom(new <> binary_part(name, byte_size(old), byte_size(name) - byte_size(old))),
      else: term
  end

  defp rename(term, old, new) when is_list(term), do: Enum.map(term, &rename(&1, old, new))

  defp rename(term, old, new) when is_tuple(term),
    do: term |> Tuple.to_list() |> rename(old, new) |> List.to_tuple()

  defp rename(term, old, new) when is_map(term),
    do: Map.new(term, fn {k, v} -> {rename(k, old, new), rename(v, old, new)} end)

  defp rename(term, _old, _new), do: term

  # Stack traces name the new generation's copy of the source.
  defp refile(forms, file) do
    Enum.map(forms, fn
      {:attribute, anno, :file, {_old, line}} -> {:attribute, anno, :file, {~c"#{file}", line}}
      form -> form
    end)
  end

  # Any string or charlist in the code that still has the old name.
  defp mentions?({:string, _anno, chars}, name) when is_list(chars),
    do: :string.find(chars, name) != :nomatch

  defp mentions?(term, name) when is_list(term), do: Enum.any?(term, &mentions?(&1, name))

  defp mentions?(term, name) when is_tuple(term),
    do: term |> Tuple.to_list() |> mentions?(name)

  defp mentions?(term, name) when is_binary(term),
    do: :binary.match(term, List.to_string(name)) != :nomatch

  defp mentions?(_term, _name), do: false
end
