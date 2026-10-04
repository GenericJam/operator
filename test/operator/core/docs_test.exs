defmodule Operator.Core.DocsTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Artifacts
  alias Operator.Core.Docs
  alias Operator.Core.Tools.ReadDoc
  alias Operator.Core.Tools.ReadGuide

  describe "read_guide" do
    test "an unknown name lists every guide" do
      assert {:error, text} = ReadGuide.run(%{"name" => "nav"}, %{})

      for name <- Docs.names(), do: assert(text =~ "\n#{name}: ")
      assert "navigation" in Docs.names()
    end

    test "a guide by name, with or without .md, any case" do
      {:ok, guide} = Docs.guide("navigation")
      assert {:ok, ^guide} = ReadGuide.run(%{"name" => "Navigation.md"}, %{})
    end

    test "a section runs from its heading to the next heading at its level or above" do
      {:ok, guide} = Docs.guide("navigation")
      lines = String.split(guide, "\n")

      [{start, level, title} | rest] =
        guide |> Docs.headings() |> Enum.drop_while(fn {_, l, _} -> l != 2 end)

      # The section has subsections: they're part of it.
      assert [{_, 3, _} | _] = rest
      {next, _, _} = Enum.find(rest, fn {_, l, _} -> l <= level end)
      expected = lines |> Enum.slice((start - 1)..(next - 2)) |> Enum.join("\n")

      assert {:ok, ^expected} =
               ReadGuide.run(%{"name" => "navigation", "section" => title}, %{})

      # A part of the heading, any case, finds it too.
      part = title |> String.slice(0, 6) |> String.upcase()

      assert {:ok, "#" <> _ = found} =
               ReadGuide.run(%{"name" => "navigation", "section" => part}, %{})

      assert String.starts_with?(found, String.duplicate("#", level) <> " ")
    end

    test "a section a guide doesn't have lists the ones it has" do
      assert {:error, text} =
               ReadGuide.run(%{"name" => "navigation", "section" => "no such thing"}, %{})

      {:ok, guide} = Docs.guide("navigation")
      for {_, _, title} <- Docs.headings(guide), do: assert(text =~ title)
    end

    test "offset and limit page through the lines and say where to continue" do
      {:ok, guide} = Docs.guide("components")
      # The guide ends with a newline: that ends its last line.
      lines = guide |> String.split("\n") |> Enum.drop(-1)
      total = length(lines)
      assert List.last(lines) != ""

      assert {:ok, page} =
               ReadGuide.run(%{"name" => "components", "offset" => 3, "limit" => 2}, %{})

      assert page ==
               Enum.join(Enum.slice(lines, 2, 2), "\n") <>
                 "\n[lines 3-4 of #{total}; continue with offset 5]"

      assert {:ok, last} =
               ReadGuide.run(%{"name" => "components", "offset" => total - 1, "limit" => 9}, %{})

      assert last ==
               Enum.join(Enum.take(lines, -2), "\n") <>
                 "\n[lines #{total - 1}-#{total} of #{total}; end]"

      assert {:ok, past} = ReadGuide.run(%{"name" => "components", "offset" => total + 1}, %{})
      refute past =~ hd(lines)
    end

    test "headings inside code fences, indented or of tildes, aren't headings" do
      text = """
      # Title

        ```elixir
      # a comment
        ```

      ## Real

      ~~~~
      ## not a heading
      ```
      ## still in the tilde fence
      ~~~~

         ### Indented heading
      """

      assert Docs.headings(text) == [{1, 1, "Title"}, {7, 2, "Real"}, {15, 3, "Indented heading"}]
      assert {:ok, "## Real\n\n~~~~" <> _} = Docs.section(text, &(&1 == "Real"))
    end

    test "a guide over the output budget starts with its sections, so the cut keeps them" do
      {:ok, guide} = Docs.guide("components")
      assert byte_size(guide) > Artifacts.budget()

      assert {:ok, text} = ReadGuide.run(%{"name" => "components"}, %{})
      assert String.ends_with?(text, guide)
      [contents | _] = String.split(text, guide)

      for {_, _, title} <- Enum.take(Docs.headings(guide), 10),
          do: assert(contents =~ title)

      {:ok, short} = Docs.guide("data")
      assert {:ok, ^short} = ReadGuide.run(%{"name" => "data"}, %{})
    end

    test "every plugin activated in mob.exs has its README, except the Core's own" do
      plugins = Config.Reader.read!("mob.exs")[:mob][:plugins]

      for plugin <- plugins -- [:mob_deliver, :mob_mishka] do
        assert {:ok, _} = Docs.guide(Atom.to_string(plugin)), "no guide for #{plugin}"
      end

      assert Docs.guide("mob_deliver") == :error
    end
  end

  describe "read_doc" do
    test "a module's moduledoc and its public functions with their signatures" do
      assert {:ok, text} = ReadDoc.run(%{"module" => "Mob.Socket"}, %{})
      assert text =~ "# Mob.Socket"
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Mob.Socket)
      assert text =~ moduledoc
      assert text =~ "- push_screen(socket, dest, params \\\\ %{}) — "
      assert text =~ "- assign(socket, key, value) — "
    end

    test "one function's doc in full, every arity" do
      assert {:ok, text} =
               ReadDoc.run(%{"module" => "Mob.Socket", "function" => "assign"}, %{})

      assert text =~ "## assign(socket, kw)"
      assert text =~ "## assign(socket, key, value)"
      refute text =~ "push_screen"

      assert {:error, _} = ReadDoc.run(%{"module" => "Mob.Socket", "function" => "nope"}, %{})
    end

    test "callbacks of a behaviour are listed" do
      assert {:ok, text} = ReadDoc.run(%{"module" => "Operator.Core.Tool"}, %{})
      assert text =~ "## Callbacks"
      assert text =~ "- parameter_schema/0 — JSON Schema"
    end

    test "an Erlang module" do
      assert {:ok, text} = ReadDoc.run(%{"module" => ":lists", "function" => "seq"}, %{})
      assert text =~ "# :lists"
      assert text =~ "seq("
    end

    test "a module that isn't there, or isn't a module name, is an error" do
      assert {:error, "No module Mob.NoSuchThing" <> _} =
               ReadDoc.run(%{"module" => "Mob.NoSuchThing"}, %{})

      assert {:error, _} = ReadDoc.run(%{"module" => "rm -rf /"}, %{})
      assert {:error, _} = ReadDoc.run(%{}, %{})
    end

    test "asking for a module that doesn't exist makes no atom" do
      n = System.unique_integer([:positive])
      assert {:error, _} = ReadDoc.run(%{"module" => "Mob.Nope#{n}"}, %{})
      assert {:error, _} = ReadDoc.run(%{"module" => ":nope_#{n}"}, %{})
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir.Mob.Nope#{n}") end
      assert_raise ArgumentError, fn -> String.to_existing_atom("nope_#{n}") end
    end

    test "a module with @moduledoc false still lists its documented functions" do
      {:docs_v1, _, _, _, :hidden, _, entries} = Code.fetch_docs(Mob.ComponentRegistry)

      documented =
        for {{:function, name, _}, _, _, doc, _} <- entries, doc != :hidden, do: name

      assert documented != []
      assert {:ok, text} = ReadDoc.run(%{"module" => "Mob.ComponentRegistry"}, %{})
      assert text =~ "@moduledoc false"
      for name <- documented, do: assert(text =~ "- #{name}(")
    end
  end
end
