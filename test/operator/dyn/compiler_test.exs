defmodule Operator.Core.Dyn.CompilerTest do
  # Loads modules into the VM-wide code server.
  use ExUnit.Case, async: false

  alias Operator.Core.Dyn.Check
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

  @tag :capture_log
  test "a compile that replaces or creates a module outside its generation leaves the VM as it was" do
    n = 977
    # What the static check refuses, compiled anyway (as a library macro might).
    source = """
    defmodule Operator.Dyn.B do
      defimpl Inspect, for: Atom do
        def inspect(_a, _o), do: Inspect.Algebra.string("pwned")
      end

      defmodule Elixir.Outside.Made do
        def x, do: 1
      end

      defstruct [:a]

      defimpl String.Chars do
        def to_string(_b), do: "b"
      end
    end
    """

    md5 = Inspect.Atom.module_info(:md5)
    on_exit(fn -> Compiler.purge(Compiler.loaded(n)) end)

    assert {:ok, build} = Compiler.compile([{"b.ex", Code.string_to_quoted!(source)}], n, [])

    # Undone at once: the stdlib's implementation is back, the stray module gone.
    assert Inspect.Atom.module_info(:md5) == md5
    assert inspect(:ok) == ":ok"
    refute :code.is_loaded(Outside.Made)

    # The generation and its own implementation stay, and the build is refused.
    own_impl = Module.concat(String.Chars, Operator.Dyn.G977.B)
    assert Enum.sort(Compiler.loaded(n)) == Enum.sort([Operator.Dyn.G977.B, own_impl])
    assert {:error, violations} = Check.beam(build.modules, n)

    assert Enum.map(violations, & &1.file) |> Enum.uniq() |> Enum.sort() == [
             "Inspect.Atom",
             "Outside.Made"
           ]
  end

  test "only a loaded implementation for a generation's module counts as one" do
    on_exit(fn -> Enum.each([Elsewhere.Operator.Dyn.G978.X, Operator.Dyn.G978.X], &unload/1) end)
    load("defmodule Elsewhere.Operator.Dyn.G978.X do\nend\n")
    assert Compiler.generation_of(Elsewhere.Operator.Dyn.G978.X) == nil
    assert Compiler.logical(Elsewhere.Operator.Dyn.G978.X) == "Elsewhere.Operator.Dyn.G978.X"
    assert Compiler.loaded(978) == []
  end
end
