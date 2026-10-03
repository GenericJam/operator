defmodule Operator.Core.Dyn.CompilerTest do
  # Loads modules into the VM-wide code server.
  use ExUnit.Case, async: false

  alias Operator.Core.Dyn.Compiler

  defp load(source) do
    [{module, _beam}] = Code.compile_string(source)
    module
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp probe(module, version) do
    unload(module)
    load("defmodule #{inspect(module)} do\n  def version, do: #{version}\nend\n")
  end

  test "the Core digest follows the Core code the VM runs, not Dyn generations' code" do
    on_exit(fn -> Enum.each([Operator.DigestProbe, Operator.Dyn.G999.DigestProbe], &unload/1) end)
    before = Compiler.core_digest()

    probe(Operator.DigestProbe, 1)
    v1 = Compiler.core_digest()
    assert v1 != before

    # Another version loaded over it, as mob_deliver loads a delivered
    # module over the build's.
    probe(Operator.DigestProbe, 2)
    assert Compiler.core_digest() not in [before, v1]

    probe(Operator.DigestProbe, 1)
    assert Compiler.core_digest() == v1

    probe(Operator.Dyn.G999.DigestProbe, 1)
    assert Compiler.core_digest() == v1
  end
end
