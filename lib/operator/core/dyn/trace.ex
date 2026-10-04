defmodule Operator.Core.Dyn.Trace do
  @moduledoc """
  An Elixir compiler tracer for Dyn compiles (`Code.put_compiler_option(:tracers, ...)`):
  which modules of the generation a file needs **at compile time**, so
  `Operator.Core.Dyn.Compiler` knows when a file compiled for an earlier
  generation can be reused as it is (`Operator.Core.Dyn.Reuse`).

  A file needs module `M` at compile time when it expands `%M{}`, imports
  or requires `M`, uses one of its macros, or calls `M` outside a function
  body (in a module attribute, say): its compiled code then depends on
  `M`'s code, not only on its name. Calls inside function bodies only name
  `M` and don't count.

  It records only while `collect/2` runs in the calling process (the
  tracer runs in the process that expands the code), so other compiles in
  the VM are untouched. `collect/2` also reports the modules the file
  defined (`:on_module`); a caller that sees fewer than it compiled treats
  the file's needs as unknown.
  """

  @key {__MODULE__, :file}

  # Events whose module is needed at compile time wherever they happen.
  @always [
    :import,
    :require,
    :struct_expansion,
    :remote_macro,
    :imported_macro,
    :imported_quoted
  ]
  # Function calls: only outside a function body.
  @calls [:remote_function, :imported_function]

  @doc "Adds this tracer to the compiler's (once per VM)."
  @spec install() :: :ok
  def install do
    tracers = Code.get_compiler_option(:tracers)
    unless __MODULE__ in tracers, do: Code.put_compiler_option(:tracers, tracers ++ [__MODULE__])
    :ok
  end

  @doc """
  Runs `fun` (one file's compile) and returns its result with what it
  traced: the modules defined and the modules named `prefix*` it needed
  at compile time.
  """
  @spec collect(String.t(), (-> result)) ::
          {result, %{defined: MapSet.t(module()), needs: MapSet.t(module())}}
        when result: term()
  def collect(prefix, fun) do
    Process.put(@key, %{prefix: prefix, defined: MapSet.new(), needs: MapSet.new()})

    try do
      result = fun.()
      %{defined: defined, needs: needs} = Process.get(@key)
      {result, %{defined: defined, needs: needs}}
    after
      Process.delete(@key)
    end
  end

  @doc false
  @spec trace(tuple() | atom(), Macro.Env.t()) :: :ok
  def trace(event, env) do
    case Process.get(@key) do
      nil -> :ok
      acc -> Process.put(@key, record(event, env, acc))
    end

    :ok
  end

  defp record({:on_module, _bytecode, _}, env, acc),
    do: %{acc | defined: MapSet.put(acc.defined, env.module)}

  defp record({kind, _meta, mod, _} = _event, _env, acc) when kind in @always,
    do: need(acc, mod)

  defp record({kind, _meta, mod, _name, _arity}, _env, acc) when kind in @always,
    do: need(acc, mod)

  defp record({kind, _meta, mod, _name, _arity}, %{function: nil}, acc) when kind in @calls,
    do: need(acc, mod)

  defp record(_event, _env, acc), do: acc

  defp need(acc, mod) when is_atom(mod) do
    if String.starts_with?(Atom.to_string(mod), acc.prefix),
      do: %{acc | needs: MapSet.put(acc.needs, mod)},
      else: acc
  end

  defp need(acc, _mod), do: acc
end
