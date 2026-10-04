defmodule Operator.Core.Term do
  @moduledoc """
  The terminal look: turns session entries into transcript rows (mob nodes).
  A row is one line: a `:wrap` of styled `:text` segments, so strong /
  emphasis / code words flow on one line and wrap between words.

  Text is Markdown (`Operator.Core.Term.Markup`, the subset omp renders).
  Colour comes only from the role (user / assistant / tool / error / notice)
  and the construct (code, headings, links, …), never from the model's text.
  Tool calls and results render from the structured entries (`toolCall`
  name + argument summary, `toolResult` head + `isError`), like omp's
  generic tool renderer.

  All styling lives in one theme map, read through `theme/0`: font, sizes,
  palette, per-role styles, per-construct styles. `put_theme/1` replaces it
  at runtime (deep-merged over `default_theme/0`), which is how the agent
  will restyle its own terminal later (a Dyn generation provides a theme).
  A style is a map with any of `:color` / `:background` (palette names),
  `:bold`, `:italic`, `:prefix` (roles only).

  Two renderers for an assistant reply's Markdown, picked by the theme's
  `:renderer` (`renderer/1`): `:term` lays it out with our own parser, row
  per line; `:native` (the default on the phone) gives each prose stretch one
  `Operator.Core.MarkdownView` row, a native Markdown view (Markwon on
  Android, Foundation's parser in a `UITextView` on iOS) that wraps inline
  styles and selects text natively. Fenced code blocks (and `$$` math) stay
  `:term` rows either way, so each code block keeps its Copy button. Every
  other entry renders the same in both.
  """

  alias Operator.Core.MarkdownView
  alias Operator.Core.Session
  alias Operator.Core.Term.Markup
  alias Operator.Core.Term.Stream, as: TermStream

  @key {__MODULE__, :theme}
  @nbsp "\u00A0"

  @spec default_theme() :: map()
  def default_theme do
    %{
      # One real face per style (JetBrains Mono, bundled from priv/fonts), so
      # bold and italic are never synthesized: mob's Android side turns a
      # system family like "monospace" into a single regular face, and
      # Compose's bold on it falls back to the default sans (see DESIGN.md).
      # Installed as Mob.Theme font tokens; `font_token/1` picks one per style.
      fonts: %{
        term:
          Mob.Theme.font("JetBrainsMono-Regular",
            from_file: "priv/fonts/JetBrainsMono-Regular.ttf"
          ),
        term_bold:
          Mob.Theme.font("JetBrainsMono-Bold", from_file: "priv/fonts/JetBrainsMono-Bold.ttf"),
        term_italic:
          Mob.Theme.font("JetBrainsMono-Italic", from_file: "priv/fonts/JetBrainsMono-Italic.ttf"),
        term_bold_italic:
          Mob.Theme.font("JetBrainsMono-BoldItalic",
            from_file: "priv/fonts/JetBrainsMono-BoldItalic.ttf"
          )
      },
      text_size: 13,
      line_height: 1.25,
      padding: 8,
      palette: %{
        "bg" => 0xFF0B0E14,
        "bar" => 0xFF11151D,
        "fg" => 0xFFD6DEEB,
        "dim" => 0xFF6B7489,
        "user" => 0xFF5FE1F2,
        "tool" => 0xFFE5C07B,
        "error" => 0xFFF2777A,
        "notice" => 0xFF8A93A6,
        "heading" => 0xFF82AAFF,
        "code" => 0xFFC3E88D,
        "code_bg" => 0xFF141922,
        "link" => 0xFF7FDBCA,
        "accent" => 0xFFC792EA
      },
      roles: %{
        user: %{color: "user", prefix: "› "},
        assistant: %{color: "fg"},
        thinking: %{color: "dim", italic: true},
        # "●" renders as text on both platforms ("⏺" gets emoji presentation on Android)
        tool_call: %{color: "tool", prefix: "● "},
        tool_result: %{color: "dim", prefix: "  ⎿ "},
        tool_error: %{color: "error", prefix: "  ⎿ "},
        error: %{color: "error", bold: true, prefix: "✗ "},
        notice: %{color: "notice", italic: true, prefix: "· "},
        aside: %{color: "accent", italic: true, prefix: "» "}
      },
      markup: %{
        bold: %{bold: true},
        italic: %{italic: true},
        del: %{color: "dim"},
        code: %{color: "code"},
        math: %{color: "code", italic: true},
        link: %{color: "link"},
        url: %{color: "dim"},
        heading: %{color: "heading", bold: true},
        item: %{color: "dim"},
        quote: %{color: "dim", prefix: "│ "},
        hr: %{color: "dim"},
        table: %{color: "fg"},
        table_header: %{color: "heading", bold: true},
        table_rule: %{color: "dim"},
        code_block: %{color: "code", background: "code_bg"},
        code_header: %{color: "dim", background: "code_bg"},
        copy: %{color: "accent", bold: true, background: "bar"}
      },
      # How much of a tool result / thinking the transcript shows.
      tool_result_lines: 3,
      thinking_lines: 3,
      max_line_chars: 160,
      # :native | :term | :auto (native on the phone, term off it)
      renderer: :auto
    }
  end

  @doc "The active theme."
  @spec theme() :: map()
  def theme, do: :persistent_term.get(@key, default_theme())

  @doc "Replaces the theme (deep-merged over the default) and installs its font."
  @spec put_theme(map()) :: :ok
  def put_theme(overrides) do
    :persistent_term.put(@key, deep_merge(default_theme(), overrides))
    install()
  end

  @doc """
  The renderer for assistant Markdown: the theme's `:renderer`, or for
  `:auto` the native view on the phone (Android and iOS) and our own parser
  off it (host tests).
  """
  @spec renderer(map(), :android | :ios | :host) :: :native | :term
  def renderer(theme \\ theme(), platform \\ platform())
  def renderer(%{renderer: r}, _platform) when r in [:native, :term], do: r
  def renderer(_theme, platform), do: if(platform in [:android, :ios], do: :native, else: :term)

  @doc "Switches the renderer in the active theme (the rest of it is kept)."
  @spec put_renderer(:native | :term | :auto) :: :ok
  def put_renderer(renderer) when renderer in [:native, :term, :auto],
    do: :persistent_term.put(@key, %{theme() | renderer: renderer})

  @doc "`:android`, `:ios`, or `:host` off the phone (asked once: off the phone the NIF fails to load, and warns, per call)."
  @spec platform() :: :android | :ios | :host
  def platform do
    with nil <- :persistent_term.get({__MODULE__, :platform}, nil) do
      p = detect_platform()
      :persistent_term.put({__MODULE__, :platform}, p)
      p
    end
  end

  defp detect_platform do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  @doc "Registers the theme's fonts (`:term`, `:term_bold`, …) as Mob.Theme font tokens."
  @spec install() :: :ok
  def install do
    t = theme()
    Mob.Theme.set({Mob.Theme.Dark, fonts: t.fonts, background: color(t, "bg")})
  end

  @doc "The font token for a style: a real face per bold / italic combination."
  @spec font_token(map()) :: :term | :term_bold | :term_italic | :term_bold_italic
  def font_token(style) do
    case {style[:bold] == true, style[:italic] == true} do
      {false, false} -> :term
      {true, false} -> :term_bold
      {false, true} -> :term_italic
      {true, true} -> :term_bold_italic
    end
  end

  @spec color(map(), String.t()) :: integer()
  def color(theme, name), do: Map.get(theme.palette, name, theme.palette["fg"])

  # ── rows ──

  @doc """
  The rows for one session entry. `key` prefixes the row ids (stable across
  re-renders, and between a reply's streaming rows and its final ones);
  `owner` is the screen pid that gets each row's long press
  (`{:long_press, {:copy, key}}`; native Markdown rows select text instead)
  and each code block's Copy tap (`{:tap, {:copy_code, key, n}}`).
  """
  @spec entry_rows(map(), String.t(), pid() | nil, map()) :: [map()]
  def entry_rows(entry, key, owner, theme \\ theme())

  def entry_rows(
        %{"type" => "message", "message" => %{"role" => "assistant"} = m},
        key,
        owner,
        theme
      ) do
    md = Session.text(m["content"])
    body = if md == "", do: [], else: body_lines(Markup.parse(md), String.split(md, "\n"), theme)

    to_rows(thinking_lines(m, theme), key, owner, theme, "#{key}.k") ++
      to_rows(body, key, owner, theme) ++
      to_rows(call_lines(m, theme), key, owner, theme, "#{key}.c")
  end

  def entry_rows(entry, key, owner, theme),
    do: entry |> entry_lines(theme) |> to_rows(key, owner, theme)

  @doc """
  Rows for assistant text still streaming (the term renderer re-parses only
  its tail; the native view gets the text so far).
  """
  @spec stream_rows(TermStream.t(), String.t(), pid() | nil, map()) :: [map()]
  def stream_rows(stream, key, owner, theme \\ theme()) do
    stream
    |> TermStream.lines()
    |> body_lines(TermStream.raw_lines(stream), theme)
    |> to_rows(key, owner, theme)
  end

  @doc "A one-off row (status lines like \"Copied\")."
  @spec notice_row(String.t(), String.t(), atom(), map()) :: map()
  def notice_row(text, id, role \\ :notice, theme \\ theme()) do
    style = theme.roles[role]
    row([{(style[:prefix] || "") <> text, style}], id, nil, nil, theme)
  end

  @doc "The plain text of an entry, for the clipboard."
  @spec plain_text(map()) :: String.t()
  def plain_text(%{"type" => "message", "message" => %{"role" => "assistant"} = m}) do
    calls =
      for c <- Session.tool_calls(m), do: "#{c["name"]}(#{Jason.encode!(c["arguments"] || %{})})"

    [Markup.plain(Session.text(m["content"])) | calls]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def plain_text(%{"type" => "message", "message" => m}), do: Session.text(m["content"])
  def plain_text(%{"type" => "custom_message", "content" => c}), do: Session.text(c)
  def plain_text(%{"type" => "compaction", "summary" => s}) when is_binary(s), do: s
  def plain_text(_entry), do: ""

  @doc """
  The rendered text of rows, one string per row: what the user sees (a
  native Markdown row: its Markdown), for tests and diagnostics.
  """
  @spec rows_text([map()]) :: [String.t()]
  def rows_text(rows),
    do:
      Enum.map(rows, fn
        %{type: :native_view, props: %{text: md}} ->
          md

        r ->
          r.children |> Enum.map_join("", & &1.props.text) |> String.replace(@nbsp, " ")
      end)

  # An entry → render lines: {:line, segs} | {:code, segs} | {:fence, lang, n}
  # | {:native, markdown}. Assistant messages render in parts (`entry_rows/4`).
  defp entry_lines(%{"type" => "message", "message" => %{"role" => "user"} = m}, theme),
    do: prefixed(Session.text(m["content"]), theme.roles.user)

  defp entry_lines(%{"type" => "message", "message" => %{"role" => "toolResult"} = m}, theme) do
    style = if m["isError"], do: theme.roles.tool_error, else: theme.roles.tool_result
    lines = m["content"] |> Session.text() |> clip(theme.tool_result_lines, theme.max_line_chars)
    lines = if lines == [], do: ["(no output)"], else: lines
    indent = String.duplicate(" ", String.length(style.prefix))

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      {:line, [{if(i == 0, do: style.prefix, else: indent) <> line, style}]}
    end)
  end

  defp entry_lines(
         %{"type" => "custom_message", "customType" => type, "content" => content},
         theme
       ) do
    role =
      case type do
        "operator.error" -> :error
        "operator.notice" -> :notice
        _ -> :aside
      end

    prefixed(Session.text(content), theme.roles[role])
  end

  defp entry_lines(%{"type" => "model_change", "model" => model}, theme),
    do: prefixed("model: #{model}", theme.roles.notice)

  defp entry_lines(%{"type" => "compaction"} = entry, theme) do
    sizes =
      case {entry["tokensBefore"], entry["tokensAfter"]} do
        {before, after_} when is_integer(before) and is_integer(after_) ->
          "#{kilo(before)} → #{kilo(after_)} tokens"

        {before, _} when is_integer(before) ->
          "#{kilo(before)} tokens summarized"

        _ ->
          "older turns summarized"
      end

    prefixed("context compacted: " <> sizes, theme.roles.notice)
  end

  defp entry_lines(_entry, _theme), do: []

  defp kilo(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp kilo(n), do: "#{n}"

  defp thinking_lines(m, theme) do
    case Session.thinking(m) do
      "" ->
        []

      t ->
        t
        |> clip(theme.thinking_lines, theme.max_line_chars)
        |> Enum.map(&{:line, [{&1, theme.roles.thinking}]})
    end
  end

  defp call_lines(m, theme) do
    calls =
      for c <- Session.tool_calls(m) do
        style = theme.roles.tool_call

        {:line,
         [
           {style.prefix, style},
           {c["name"], Map.put(style, :bold, true)},
           {"(#{args_summary(c["arguments"])})", style}
         ]}
      end

    errors = if m["errorMessage"], do: prefixed(m["errorMessage"], theme.roles.error), else: []
    calls ++ errors
  end

  # A reply's Markdown (parsed lines and their source, one for one) → render
  # lines, by the theme's renderer.
  defp body_lines(parsed, raw, theme) do
    case renderer(theme) do
      :term -> parsed |> markdown(0, theme) |> elem(0)
      :native -> native_lines(parsed, raw, theme)
    end
  end

  # Prose stretches become one native Markdown view each; fenced code (an
  # unclosed fence runs to the end, as while streaming) and `$$` math stay
  # term rows, numbered as `Markup.code_block/2` counts them.
  defp native_lines(parsed, raw, theme) do
    {out, _blocks} =
      parsed
      |> Enum.zip(raw)
      |> Enum.chunk_by(fn {line, _raw} -> term_line?(line) end)
      |> Enum.flat_map_reduce(0, fn [{first, _} | _] = chunk, n ->
        if term_line?(first),
          do: chunk |> Enum.map(&elem(&1, 0)) |> markdown(n, theme),
          else: {prose(chunk), n}
      end)

    out
  end

  defp term_line?({kind, _}) when kind in [:fence_open, :code, :math], do: true
  defp term_line?(delimiter), do: delimiter in [:fence_close, :math_delim]

  # Blank lines at either end of a stretch only add height.
  defp prose(chunk) do
    lines =
      chunk
      |> Enum.drop_while(&match?({:blank, _}, &1))
      |> Enum.reverse()
      |> Enum.drop_while(&match?({:blank, _}, &1))
      |> Enum.reverse()

    if lines == [], do: [], else: [{:native, Enum.map_join(lines, "\n", &elem(&1, 1))}]
  end

  defp args_summary(args) when is_map(args) and map_size(args) > 0 do
    args
    |> Enum.map_join(", ", fn {k, v} ->
      "#{k}: #{if is_binary(v), do: inspect(v), else: Jason.encode!(v)}"
    end)
    |> clip_line(80)
  end

  defp args_summary(_args), do: ""

  defp prefixed(text, style) do
    prefix = style[:prefix] || ""
    indent = String.duplicate(" ", String.length(prefix))

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      {:line, [{if(i == 0, do: prefix, else: indent) <> line, style}]}
    end)
  end

  defp clip(text, max_lines, max_chars) do
    lines = text |> String.trim_trailing() |> String.split("\n")
    lines = if lines == [""], do: [], else: lines
    shown = lines |> Enum.take(max_lines) |> Enum.map(&clip_line(&1, max_chars))
    more = length(lines) - max_lines
    if more > 0, do: shown ++ ["… (#{more} more lines)"], else: shown
  end

  defp clip_line(line, max),
    do: if(String.length(line) > max, do: String.slice(line, 0, max) <> "…", else: line)

  # Parsed Markdown lines → render lines. Consecutive table lines are laid
  # out together (columns padded to the widest cell, monospace). `n` numbers
  # the code blocks; returns `{render_lines, next_n}`.
  defp markdown(lines, n, theme) do
    lines
    |> Enum.chunk_by(&table_line?/1)
    |> Enum.flat_map_reduce(n, fn
      [first | _] = chunk, n ->
        if table_line?(first), do: {table(chunk, theme), n}, else: md_lines(chunk, n, theme)
    end)
  end

  defp md_lines(lines, n, theme) do
    Enum.flat_map_reduce(lines, n, fn line, n ->
      case line do
        {:fence_open, lang} -> {[{:fence, lang, n}], n + 1}
        other -> {md_line(other, theme), n}
      end
    end)
  end

  defp table_line?({:table_row, _}), do: true
  defp table_line?(:table_sep), do: true
  defp table_line?(_), do: false

  defp md_line(:blank, _theme), do: [{:line, [{" ", %{}}]}]
  defp md_line(:hr, theme), do: [{:line, [{String.duplicate("─", 24), theme.markup.hr}]}]
  defp md_line(d, _theme) when d in [:fence_close, :math_delim], do: []

  defp md_line({:para, segs, _raw}, theme),
    do: split_br(styled(segs, theme.roles.assistant, theme))

  defp md_line({:heading, _level, segs}, theme),
    do: split_br(styled(segs, Map.merge(theme.roles.assistant, theme.markup.heading), theme))

  defp md_line({:item, indent, marker, segs}, theme),
    do:
      split_br([
        {indent <> marker <> " ", theme.markup.item} | styled(segs, theme.roles.assistant, theme)
      ])

  defp md_line({:quote, depth, segs}, theme) do
    q = theme.markup.quote

    split_br([
      {String.duplicate(q.prefix, depth), q}
      | styled(segs, Map.merge(theme.roles.assistant, q), theme)
    ])
  end

  defp md_line({:code, line}, theme),
    do: [{:code, [{if(line == "", do: " ", else: line), theme.markup.code_block}]}]

  defp md_line({:math, line}, theme),
    do: [{:code, [{line, Map.merge(theme.markup.code_block, theme.markup.math)}]}]

  defp table(lines, theme) do
    rows = for {:table_row, cells} <- lines, do: cells
    cols = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    widths =
      for c <- 0..max(cols - 1, 0),
          do: rows |> Enum.map(&String.length(Enum.at(&1, c, ""))) |> Enum.max(fn -> 0 end)

    sep = theme.markup.table_rule

    Enum.flat_map(lines, fn
      :table_sep ->
        [{:line, [{Enum.map_join(widths, "─┼─", &String.duplicate("─", &1)), sep}]}]

      {:table_row, cells} ->
        style = if header?(cells, lines), do: theme.markup.table_header, else: theme.markup.table

        text =
          widths
          |> Enum.with_index()
          |> Enum.map_join(" │ ", fn {w, c} -> String.pad_trailing(Enum.at(cells, c, ""), w) end)

        [{:code, [{text, style}]}]
    end)
  end

  defp header?(cells, [{:table_row, cells}, :table_sep | _]), do: true
  defp header?(_cells, _lines), do: false

  defp split_br(segs) do
    segs
    |> Enum.chunk_by(&(&1 == :br))
    |> Enum.reject(fn chunk -> Enum.all?(chunk, &(&1 == :br)) end)
    |> Enum.map(&{:line, &1})
    |> case do
      [] -> [{:line, [{" ", %{}}]}]
      lines -> lines
    end
  end

  defp styled(segs, base, theme) do
    Enum.map(segs, fn
      :br ->
        :br

      {text, styles} ->
        {text, Enum.reduce(styles, base, &Map.merge(&2, Map.get(theme.markup, &1, %{})))}
    end)
  end

  # Row ids are "<prefix>.<i>"; `key` tags the copy events.
  defp to_rows(lines, key, owner, theme, prefix \\ nil) do
    prefix = prefix || key

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {{:fence, lang, n}, i} ->
        label = {"─ " <> if(lang == "", do: "code", else: lang) <> " ", theme.markup.code_header}
        copy = {" Copy ", theme.markup.copy, owner && {owner, {:copy_code, key, n}}}
        row([label, copy], "#{prefix}.#{i}", owner, key, theme, theme.markup.code_header)

      {{:code, segs}, i} ->
        row(segs, "#{prefix}.#{i}", owner, key, theme, theme.markup.code_block)

      {{:line, segs}, i} ->
        row(segs, "#{prefix}.#{i}", owner, key, theme)

      {{:native, md}, i} ->
        native_row(md, "#{prefix}.#{i}", theme)
    end)
  end

  # Mob.UI.native_view ids are atoms (one per row slot, reused by every
  # session: keys restart at "m0").
  defp native_row(md, id, theme) do
    props =
      theme
      |> markdown_props()
      |> Map.merge(%{id: String.to_atom(id), text: md})

    Mob.UI.native_view(MarkdownView, props)
  end

  @doc """
  The theme as `Operator.Core.MarkdownView` props (everything but `:id` and
  `:text`): colours as ARGB integers, sizes in sp, and the four faces by the
  names the platform loads them by (iOS: PostScript names; Android, and off
  the phone: font resource names).
  """
  @spec markdown_props(map(), :android | :ios | :host) :: map()
  def markdown_props(theme \\ theme(), platform \\ platform()) do
    m = theme.markup

    %{
      text_size: theme.text_size,
      line_height: theme.line_height,
      text_color: color(theme, theme.roles.assistant.color),
      heading_color: color(theme, m.heading.color),
      link_color: color(theme, m.link.color),
      code_color: color(theme, m.code.color),
      code_background: color(theme, m.code_block.background),
      quote_color: color(theme, m.quote.color),
      rule_color: color(theme, m.hr.color),
      selection_color: color(theme, m.copy.color),
      font_regular: font_name(theme.fonts.term, platform),
      font_bold: font_name(theme.fonts.term_bold, platform),
      font_italic: font_name(theme.fonts.term_italic, platform),
      font_bold_italic: font_name(theme.fonts.term_bold_italic, platform)
    }
  end

  defp font_name(%{ios: name}, :ios), do: name
  defp font_name(%{android: name}, _platform), do: name
  defp font_name(name, _platform) when is_binary(name), do: name

  defp row(segs, id, owner, key, theme, row_style \\ %{}) do
    props = %{id: id, fill_width: true}
    props = if owner, do: Map.put(props, :on_long_press, {owner, {:copy, key}}), else: props

    props =
      if row_style[:background],
        do: Map.put(props, :background, color(theme, row_style.background)),
        else: props

    %{type: :wrap, props: props, children: segment_nodes(segs, theme)}
  end

  # One style for the whole line: one text node, wrapped natively. Mixed
  # styles: one node per word (a trailing no-break space keeps the gap), so
  # the wrap layout flows the words and breaks lines between them.
  defp segment_nodes(segs, theme) do
    if mixed?(segs) do
      Enum.flat_map(segs, &word_nodes(&1, theme))
    else
      [text_node(Enum.map_join(segs, "", &elem(&1, 0)), segs |> hd() |> elem(1), theme)]
    end
  end

  defp mixed?(segs),
    do: segs |> Enum.map(&{elem(&1, 1), tap_of(&1)}) |> Enum.uniq() |> length() > 1

  defp tap_of({_, _, tap}), do: tap
  defp tap_of(_), do: nil

  defp word_nodes({text, style, nil}, theme), do: [text_node(text, style, theme)]

  defp word_nodes({text, style, tap}, theme),
    do: [text_node(text, style, theme) |> put_in([:props, :on_tap], tap)]

  defp word_nodes({text, style}, theme) do
    pieces = String.split(text, " ")
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", ^last} -> []
      {piece, ^last} -> [text_node(piece, style, theme)]
      {piece, _} -> [text_node(piece <> @nbsp, style, theme)]
    end)
  end

  defp text_node(text, style, theme) do
    props = %{
      text: text,
      font: font_token(style),
      text_size: theme.text_size,
      line_height: theme.line_height,
      text_color: color(theme, style[:color] || "fg")
    }

    props =
      if style[:background],
        do: Map.put(props, :background, color(theme, style.background)),
        else: props

    %{type: :text, props: props, children: []}
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _k, x, y -> deep_merge(x, y) end)

  defp deep_merge(_a, b), do: b
end
