defmodule Operator.Core.Dyn.ReuseTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Reuse
  alias Operator.Core.Dyn.Store

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    purge_all()
    on_exit(&purge_all/0)
    start_keeper(dir)
    %{dir: dir}
  end

  defp name(value) do
    """
    defmodule Operator.Dyn.Name do
      def value, do: #{inspect(value)}
    end
    """
  end

  # Files around Operator.Dyn.Name, each depending on it a different way.
  defp files(value) do
    %{
      "name.ex" => name(value),
      # Names it at run time only.
      "greeter.ex" => """
      defmodule Operator.Dyn.Greeter do
        def hello, do: "hello " <> Operator.Dyn.Name.value()
        def screens, do: [%{module: Operator.Dyn.Name}]
      end
      """,
      # Calls it at compile time.
      "frozen.ex" => """
      defmodule Operator.Dyn.Frozen do
        @value Operator.Dyn.Name.value()
        def value, do: @value
      end
      """,
      # Calls, at compile time, a module that names it at run time.
      "relay.ex" => """
      defmodule Operator.Dyn.Relay do
        def value, do: Operator.Dyn.Name.value()
      end
      """,
      "via.ex" => """
      defmodule Operator.Dyn.Via do
        @value Operator.Dyn.Relay.value()
        def value, do: @value
      end
      """,
      # A struct whose default comes from it, and a module expanding that struct.
      "card.ex" => """
      defmodule Operator.Dyn.Card do
        defstruct title: Operator.Dyn.Name.value()
      end
      """,
      "deck.ex" => """
      defmodule Operator.Dyn.Deck do
        alias Operator.Dyn.Card
        def first, do: %Card{}
      end
      """,
      # Unrelated: a plain struct and a module using it.
      "plain.ex" => """
      defmodule Operator.Dyn.Plain do
        defstruct label: "plain"
      end
      """,
      "user.ex" => """
      defmodule Operator.Dyn.User do
        alias Operator.Dyn.Plain
        def plain, do: %Plain{}.label
        def greeting, do: Operator.Dyn.Greeter.hello()
      end
      """,
      # Its own (versioned) name as a string, frozen at compile time.
      "label.ex" => """
      defmodule Operator.Dyn.Label do
        @label inspect(__MODULE__)
        def label, do: @label
      end
      """
    }
  end

  defp mod(n, name), do: Module.concat(["Operator.Dyn.G#{n}", name])
  defp call(n, name, fun), do: apply(mod(n, name), fun, [])

  test "a change recompiles what depends on it at compile time and reuses the rest",
       %{dir: dir} do
    one = activate!(files("one"))
    assert %{"files" => %{"greeter.ex" => %{"needs" => []}}} = Store.deps(dir, one)

    assert %{"needs" => ["Operator.Dyn.Relay"]} = Store.deps(dir, one)["files"]["via.ex"]
    assert %{"needs" => ["Operator.Dyn.Card"]} = Store.deps(dir, one)["files"]["deck.ex"]

    assert %{reused: reused, n: two} = propose!(%{"name.ex" => name("two")})
    {:ok, token} = Dyn.request_approval({:activate, two})
    {:ok, _} = Dyn.activate(two, token)

    # Reused (renamed): their calls reach the new generation.
    assert call(two, "Greeter", :hello) == "hello two"
    assert call(two, "Greeter", :screens) == [%{module: mod(two, "Name")}]
    assert call(two, "User", :greeting) == "hello two"
    assert call(two, "User", :plain) == "plain"
    assert call(two, "Relay", :value) == "two"
    # Recompiled: they froze the old value at compile time.
    assert call(two, "Frozen", :value) == "two"
    assert call(two, "Via", :value) == "two"
    assert call(two, "Deck", :first) == struct(mod(two, "Card"), title: "two")
    # Recompiled from source: its code held the old generation's name.
    assert call(two, "Label", :label) == "Operator.Dyn.G#{two}.Label"

    # greeter, relay, plain, user; name, frozen, via, card, deck, label compiled.
    assert reused == 4
    assert {:ok, %{compile_ms: _}} = Dyn.generation(two)
    # The old generation still runs its own code.
    assert call(one, "Greeter", :hello) == "hello one"

    # The reused generation is itself reused from, and its deps carry over.
    assert Store.deps(dir, two)["files"]["via.ex"] == Store.deps(dir, one)["files"]["via.ex"]

    assert %{reused: 9} =
             propose!(%{"label.ex" => String.replace(files("x")["label.ex"], "label", "tag")})
  end

  test "nothing is reused from a parent built by another runtime or without deps",
       %{dir: dir} do
    one = activate!(files("one"))
    {:ok, _} = Store.update_generation(dir, one, &%{&1 | runtime: "an older app"})
    assert %{reused: 0} = propose!(%{"name.ex" => name("two")})

    {:ok, _} = Store.update_generation(dir, one, &%{&1 | runtime: Compiler.runtime()})

    File.rm!(Path.join([dir, "gens", "#{one}", "deps.json"]))
    assert %{reused: 0} = propose!(%{"name.ex" => name("three")})
  end

  test "plan: unchanged files are reused unless a compile-time need reaches a change" do
    deps = %{
      "files" => %{
        "a.ex" => %{"modules" => ["A"], "needs" => []},
        "b.ex" => %{"modules" => ["B"], "needs" => ["A"]},
        "c.ex" => %{"modules" => ["C"], "needs" => ["B"]},
        "d.ex" => %{"modules" => ["D"], "needs" => ["E"]},
        "e.ex" => %{"modules" => ["E"], "needs" => []},
        "f.ex" => %{"modules" => ["F"], "needs" => nil},
        "g.ex" => %{"modules" => ["G"], "needs" => ["H"]},
        "h.ex" => %{"modules" => ["H"], "needs" => []}
      },
      # E names A at run time; H has no recorded names.
      "refs" => %{"A" => [], "B" => [], "C" => [], "D" => [], "E" => ["A"], "F" => [], "G" => []}
    }

    all = MapSet.new(Map.keys(deps["files"]))

    # Nothing changed: all but f (its needs are unknown) and g (it needs H,
    # whose names are unknown, while f is dirty).
    assert Reuse.plan(deps, all) == MapSet.new(~w(a.ex b.ex c.ex d.ex e.ex h.ex))

    # a changed: b needs it; c needs b (now dirty); d needs e, which names a.
    assert Reuse.plan(deps, MapSet.delete(all, "a.ex")) == MapSet.new(~w(e.ex h.ex))
    assert Reuse.plan(nil, all) == MapSet.new()
  end
end
