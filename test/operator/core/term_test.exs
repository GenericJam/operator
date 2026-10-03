defmodule Operator.Core.TermTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Session
  alias Operator.Core.Term
  alias Operator.Core.Term.Markup
  alias Operator.Core.Term.Stream, as: TermStream

  @fixture Path.expand("../../fixtures/omp_session.jsonl", __DIR__)

  describe "inline markup" do
    test "nesting, code spans and strikethrough" do
      assert Markup.inline("a **b *c* d** `x` ~~gone~~") == [
               {"a ", []},
               {"b ", [:bold]},
               {"c", [:bold, :italic]},
               {" d", [:bold]},
               {" ", []},
               {"x", [:code]},
               {" ", []},
               {"gone", [:del]}
             ]
    end

    test "an unclosed ** (mid-stream) renders as plain text, never as raw markup" do
      assert Markup.inline("so **bol") == [{"so bol", []}]
      assert Markup.inline("so **bold**") == [{"so ", []}, {"bold", [:bold]}]
      assert Markup.inline("~~half") == [{"half", []}]
    end

    test "lone asterisks and snake_case stay as written" do
      assert Markup.inline("2 * 3 * 4") == [{"2 * 3 * 4", []}]
      assert Markup.inline("call my_fun_name now") == [{"call my_fun_name now", []}]

      assert Markup.inline("_em_ and __strong__") == [
               {"em", [:italic]},
               {" and ", []},
               {"strong", [:bold]}
             ]
    end

    test "links show their text and a muted URL; bare URLs and autolinks are links" do
      assert Markup.inline("see [docs](https://x.dev/a) now") ==
               [{"see ", []}, {"docs", [:link]}, {" (https://x.dev/a)", [:url]}, {" now", []}]

      assert Markup.inline("at https://x.dev/b.") == [
               {"at ", []},
               {"https://x.dev/b", [:link]},
               {".", []}
             ]

      assert Markup.inline("<https://x.dev>") == [{"https://x.dev", [:link]}]
      assert Markup.inline("![chart](c.png)") == [{"[image: chart]", []}]
    end

    test "HTML: br breaks the line, known tags style, other tags vanish, entities decode" do
      assert Markup.inline("a<br>b") == [{"a", []}, :br, {"b", []}]

      assert Markup.inline("<b>x</b> <code>y</code> <span class=\"z\">s</span>") ==
               [{"x", [:bold]}, {" ", []}, {"y", [:code]}, {" s", []}]

      assert Markup.inline("a &amp; b &lt;3 &#x2713;") == [{"a & b <3 ✓", []}]
    end

    test "math shows its source; money is not math" do
      assert Markup.inline("area $\\pi r^2$ here") == [
               {"area ", []},
               {"\\pi r^2", [:math]},
               {" here", []}
             ]

      assert Markup.inline("costs $5 and $10") == [{"costs $5 and $10", []}]
      assert Markup.inline("\\*not em\\*") == [{"*not em*", []}]
    end
  end

  describe "blocks" do
    test "fences keep code verbatim and their language" do
      assert Markup.parse("```elixir\n**not bold** `x`\n\n```\nafter") == [
               {:fence_open, "elixir"},
               {:code, "**not bold** `x`"},
               {:code, ""},
               :fence_close,
               {:para, [{"after", []}], "after"}
             ]

      assert [{:fence_open, ""}, {:code, "a"}, :fence_close] = Markup.parse("~~~\na\n~~~")
    end

    test "headings, lists, task lists, quotes, rules" do
      assert [
               {:heading, 2, [{"Title", []}]},
               {:item, "", "•", [{"one", []}]},
               {:item, "  ", "2.", [{"two", [:bold]}]},
               {:item, "", "☑", [{"done", []}]},
               {:quote, 2, [{"deep", []}]},
               :hr
             ] = Markup.parse("## Title\n- one\n  2. **two**\n- [x] done\n> > deep\n---")
    end

    test "tables, with or without outer pipes; the header line is retro-fitted" do
      assert [
               {:table_row, ["Repo", "Does"]},
               :table_sep,
               {:table_row, ["mob", "runtime"]},
               :blank,
               {:table_row, ["a", "b"]},
               :table_sep,
               {:table_row, ["1", "2"]}
             ] =
               Markup.parse(
                 "| Repo | **Does** |\n|---|:--|\n| `mob` | runtime |\n\na | b\n--|--\n1 | 2"
               )
    end

    test "streaming: feeding any chunking gives the same lines as parsing the whole" do
      text =
        "# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```sh\nmix test\n```\n- **done** item\n> quoted"

      whole = Markup.parse(text)

      for size <- [1, 3, 7, 40] do
        chunks = text |> String.graphemes() |> Enum.chunk_every(size) |> Enum.map(&Enum.join/1)
        stream = Enum.reduce(chunks, TermStream.new(), &TermStream.feed(&2, &1))
        assert TermStream.lines(stream) == whole
      end
    end
  end

  test "plain text for copying strips markup and keeps code verbatim" do
    text = "## Run\nUse **this**:\n```sh\nmix  test --only x\n```\n- see [docs](https://d.dev)"
    assert Markup.plain(text) == "Run\nUse this:\nmix  test --only x\n- see docs (https://d.dev)"
    assert Markup.code_block(text, 0) == "mix  test --only x"
    assert Markup.code_block("```\na\n```\n```\nb\nc", 1) == "b\nc"
    assert Markup.code_block(text, 1) == nil
  end

  describe "rows" do
    setup do
      %{owner: self(), theme: Term.default_theme()}
    end

    defp texts(row), do: Enum.map(row.children, & &1.props)

    test "user input: role color and the › prefix", %{owner: owner, theme: t} do
      [row] = Term.entry_rows(Session.user("hello"), "m0", owner)
      assert [%{text: "› hello", text_color: color, font: :term}] = texts(row)
      assert color == Term.color(t, "user")
      assert row.props.on_long_press == {owner, {:copy, "m0"}}
      assert row.props.id == "m0.0"
    end

    test "assistant markdown: mixed styles flow word by word", %{owner: owner, theme: t} do
      entry =
        Session.assistant(%{text: "Run **mix test** now", stop_reason: "stop"}, "openrouter:x/y")

      [row] = Term.entry_rows(entry, "m1", owner)

      assert [
               %{text: "Run\u00A0"},
               %{text: "mix\u00A0", font_weight: "bold"},
               %{text: "test"} = test,
               %{text: "\u00A0"},
               %{text: "now"}
             ] =
               texts(row)

      assert test.font_weight == "bold"
      assert test.text_color == Term.color(t, "fg")
    end

    test "tool calls and results render from the structured entries", %{owner: owner, theme: t} do
      call = %{"id" => "c", "name" => "notes", "arguments" => %{"action" => "read"}}

      entry =
        Session.assistant(
          %{text: "", tool_calls: [call], stop_reason: "toolUse"},
          "openrouter:x/y"
        )

      assert ["⏺ notes(action: \"read\")"] =
               entry |> Term.entry_rows("m2", owner) |> Term.rows_text()

      [row] = Term.entry_rows(entry, "m2", owner)
      assert Enum.all?(texts(row), &(&1.text_color == Term.color(t, "tool")))

      ok = Session.tool_result("c", "notes", "line1\nline2\nline3\nline4", false)

      assert Term.rows_text(Term.entry_rows(ok, "m3", owner)) == [
               "  ⎿ line1",
               "    line2",
               "    line3",
               "    … (1 more lines)"
             ]

      err = Session.tool_result("c", "notes", "Tool crashed: boom", true)
      [row] = Term.entry_rows(err, "m4", owner)
      assert [%{text_color: color}] = texts(row)
      assert color == Term.color(t, "error")
    end

    test "errors are red and bold; notices italic", %{owner: owner, theme: t} do
      failed =
        Session.assistant(
          %{text: "", stop_reason: "error", error: "OpenRouter 402"},
          "openrouter:x/y"
        )

      [row] = Term.entry_rows(failed, "m5", owner)
      assert [%{text: "✗ OpenRouter 402", font_weight: "bold", text_color: red}] = texts(row)
      assert red == Term.color(t, "error")

      [row] = Term.entry_rows(Session.custom(:notice, "Stopped by the user."), "m6", owner)
      assert [%{text: "· Stopped by the user.", italic: true}] = texts(row)
    end

    test "a code block gets a Copy button; no fence lines are shown", %{owner: owner} do
      entry =
        Session.assistant(%{text: "```sh\nmix test\n```", stop_reason: "stop"}, "openrouter:x/y")

      [header, code] = Term.entry_rows(entry, "m7", owner)

      assert [
               %{text: "─\u00A0"},
               %{text: "sh\u00A0"},
               %{text: " Copy ", on_tap: {^owner, {:copy_code, "m7", 0}}}
             ] = texts(header)

      assert [%{text: "mix test"}] = texts(code)
      assert code.props.background
    end

    test "the theme is one map; put_theme replaces what rows use" do
      on_exit(fn -> :persistent_term.erase({Term, :theme}) end)

      :persistent_term.put(
        {Term, :theme},
        put_in(Term.default_theme(), [:palette, "user"], 0xFF00FF00)
      )

      [row] = Term.entry_rows(Session.user("hi"), "m0", self())
      assert [%{text_color: 0xFF00FF00}] = texts(row)
    end
  end

  test "a real omp transcript renders with no raw Markdown left" do
    {:ok, _session, entries} = Session.open(@fixture, "unused")
    assistants = for %{"message" => %{"role" => "assistant"}} = e <- entries, do: e

    texts =
      assistants
      |> Enum.with_index()
      |> Enum.flat_map(fn {e, i} -> Term.rows_text(Term.entry_rows(e, "m#{i}", self())) end)

    assert Enum.count(texts) > 50

    refute Enum.any?(texts, &String.contains?(&1, "**")),
           "raw ** in #{inspect(Enum.filter(texts, &String.contains?(&1, "**")))}"

    refute Enum.any?(texts, &String.starts_with?(String.trim_leading(&1), "```"))
    refute Enum.any?(texts, &Regex.match?(~r/\|\s*:?-{3,}/, &1))
    refute Enum.any?(texts, &Regex.match?(~r/<\/?[a-zA-Z][^>]*>/, &1))
    refute Enum.any?(texts, &Regex.match?(~r/^\s*#+\s/, &1))

    # the table in the fixture is laid out in aligned columns
    table = Enum.filter(texts, &String.contains?(&1, " │ "))
    assert ["Repo" <> _ = header | rows] = table
    assert Enum.all?(rows, &(String.length(&1) >= String.length(String.trim_trailing(header))))
  end
end
