defmodule Operator.Core.TermTest do
  use ExUnit.Case, async: true

  alias Operator.Core.MarkdownView
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

    test "*** is bold italic, alone or closing / opening separate markers" do
      assert Markup.inline("a ***both*** b") == [
               {"a ", []},
               {"both", [:bold, :italic]},
               {" b", []}
             ]

      assert Markup.inline("**a *b***") == [{"a ", [:bold]}, {"b", [:bold, :italic]}]
      assert Markup.inline("***a* b**") == [{"a", [:bold, :italic]}, {" b", [:bold]}]
      assert Markup.inline("***a** b*") == [{"a", [:bold, :italic]}, {" b", [:italic]}]
      # unclosed while streaming: like an unclosed ** plus a lone *
      assert Markup.inline("***bol") == [{"*bol", []}]

      entry = Session.assistant(%{text: "***x***", stop_reason: "stop"}, "openrouter:x/y")
      [row] = Term.entry_rows(entry, "m0", self(), Term.default_theme())
      assert [%{props: %{text: "x", font: :term_bold_italic}}] = row.children
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
               %{text: "Run\u00A0", font: :term},
               %{text: "mix\u00A0", font: :term_bold},
               %{text: "test"} = test,
               %{text: "\u00A0"},
               %{text: "now"}
             ] =
               texts(row)

      # a real bold face, never a synthesized weight
      assert test.font == :term_bold
      refute Enum.any?(texts(row), &(Map.has_key?(&1, :font_weight) or Map.has_key?(&1, :italic)))
      assert test.text_color == Term.color(t, "fg")
    end

    test "tool calls and results render from the structured entries", %{owner: owner, theme: t} do
      call = %{"id" => "c", "name" => "notes", "arguments" => %{"action" => "read"}}

      entry =
        Session.assistant(
          %{text: "", tool_calls: [call], stop_reason: "toolUse"},
          "openrouter:x/y"
        )

      assert ["● notes(action: \"read\")"] =
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
      assert [%{text: "✗ OpenRouter 402", font: :term_bold, text_color: red}] = texts(row)
      assert red == Term.color(t, "error")

      [row] = Term.entry_rows(Session.custom(:notice, "Stopped by the user."), "m6", owner)
      assert [%{text: "· Stopped by the user.", font: :term_italic}] = texts(row)
    end

    test "each style picks its own face" do
      assert Term.font_token(%{}) == :term
      assert Term.font_token(%{bold: true}) == :term_bold
      assert Term.font_token(%{italic: true}) == :term_italic
      assert Term.font_token(%{bold: true, italic: true}) == :term_bold_italic
      fonts = Term.default_theme().fonts
      assert fonts.term_bold == %{ios: "JetBrainsMono-Bold", android: "jetbrainsmono_bold"}
      assert Enum.all?(Map.keys(fonts), &File.exists?("priv/fonts/#{fonts[&1].ios}.ttf"))
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

  describe "native renderer" do
    setup do
      %{theme: %{Term.default_theme() | renderer: :native}}
    end

    defp reply(text, extra \\ %{}),
      do:
        Session.assistant(Map.merge(%{text: text, stop_reason: "stop"}, extra), "openrouter:x/y")

    defp shape(rows) do
      Enum.map(rows, fn
        %{type: :native_view, props: p} -> {:native, p.id, p.text}
        %{props: %{id: id}} = r -> {:term, id, r |> List.wrap() |> Term.rows_text() |> hd()}
      end)
    end

    test "prose stretches become native views; code blocks stay term rows with Copy", %{
      theme: t
    } do
      text =
        "Intro **x**\n\n```sh\nmix test\n```\n\nThen:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n" <>
          "```\nb\n```\n$$\nE = mc^2\n$$\nEnd"

      rows = Term.entry_rows(reply(text), "m1", self(), t)

      assert shape(rows) == [
               {:native, :"m1.0", "Intro **x**"},
               {:term, "m1.1", "─ sh  Copy "},
               {:term, "m1.2", "mix test"},
               {:native, :"m1.3", "Then:\n\n| a | b |\n|---|---|\n| 1 | 2 |"},
               {:term, "m1.4", "─ code  Copy "},
               {:term, "m1.5", "b"},
               {:term, "m1.6", "E = mc^2"},
               {:native, :"m1.7", "End"}
             ]

      # each Copy addresses the block Markup.code_block/2 returns
      copies =
        for r <- rows, c <- r.children, tap = c.props[:on_tap], do: tap

      owner = self()
      assert [{^owner, {:copy_code, "m1", 0}}, {^owner, {:copy_code, "m1", 1}}] = copies
      assert Markup.code_block(text, 0) == "mix test" and Markup.code_block(text, 1) == "b"

      # native rows carry the theme and select text instead of copying on long press
      [native | _] = rows
      assert native.props.module == MarkdownView
      assert Map.drop(native.props, [:module, :id, :text]) == Term.markdown_props(t)
      refute Map.has_key?(native.props, :on_long_press)
      assert Term.markdown_props(t).font_bold_italic == "jetbrainsmono_bolditalic"
      assert Term.markdown_props(t).heading_color == Term.color(t, "heading")
    end

    test "streaming: the open fence is code to the end; ids match the final rows", %{theme: t} do
      chunks = ["Hi ", "**there**\n\n```eli", "xir\nIO.puts 1\nmo", "re"]
      stream = Enum.reduce(chunks, TermStream.new(), &TermStream.feed(&2, &1))

      assert shape(Term.stream_rows(stream, "m2", self(), t)) == [
               {:native, :"m2.0", "Hi **there**"},
               {:term, "m2.1", "─ elixir  Copy "},
               {:term, "m2.2", "IO.puts 1"},
               {:term, "m2.3", "more"}
             ]

      # the finished reply (thinking and tool calls added) keeps the text rows' ids
      call = %{"id" => "c", "name" => "notes", "arguments" => %{}}
      text = Enum.join(chunks) <> "\n```"
      final = reply(text, %{thinking: "hmm", tool_calls: [call]})
      ids = final |> Term.entry_rows("m2", self(), t) |> Enum.map(& &1.props.id)
      assert ids == ["m2.k.0", :"m2.0", "m2.1", "m2.2", "m2.3", "m2.c.0"]
    end

    test "the term renderer is one flag away and the default off Android", %{theme: t} do
      text = "Intro **x**\n```sh\nmix test\n```"
      term = %{t | renderer: :term}
      rows = Term.entry_rows(reply(text), "m3", self(), term)
      refute Enum.any?(rows, &(&1.type == :native_view))
      assert Term.rows_text(rows) == ["Intro x", "─ sh  Copy ", "mix test"]

      assert Term.renderer(t) == :native
      assert Term.renderer(term) == :term
      # host tests: no NIF, so :auto picks the parser
      assert Term.renderer(Term.default_theme()) == :term
    end
  end

  test "the native view forwards its props and opens only web and mail links" do
    props = %{module: MarkdownView, id: :"m0.0", text: "*hi*", text_size: 13}
    {:ok, socket} = MarkdownView.mount(props, Mob.Socket.new(MarkdownView))
    assert MarkdownView.render(socket.assigns) == %{text: "*hi*", text_size: 13}

    assert MarkdownView.openable?("https://x.dev/a")
    assert MarkdownView.openable?("mailto:k@x.dev")
    refute MarkdownView.openable?("intent://scan#Intent;end")
    refute MarkdownView.openable?("javascript:alert(1)")
    refute MarkdownView.openable?("file:///data/x")

    # a refused link never reaches the NIF (which isn't loaded here)
    assert {:noreply, ^socket} =
             MarkdownView.handle_event("open_link", %{"url" => "file:///x"}, socket)
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
