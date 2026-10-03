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
  """

  alias Operator.Core.Session
  alias Operator.Core.Term.Markup

  @key {__MODULE__, :theme}
  @nbsp "\u00A0"

  @spec default_theme() :: map()
  def default_theme do
    %{
      # Monospace on both platforms (`font: :term` resolves through Mob.Theme's
      # fonts map): Android's system "monospace" family, iOS's Menlo.
      font: %{ios: "Menlo-Regular", android: "monospace"},
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
        tool_call: %{color: "tool", prefix: "⏺ "},
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
      max_line_chars: 160
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

  @doc "Registers the theme's font as the `:term` font token in Mob's theme."
  @spec install() :: :ok
  def install do
    t = theme()
    Mob.Theme.set({Mob.Theme.Dark, fonts: %{term: t.font}, background: color(t, "bg")})
  end

  @spec color(map(), String.t()) :: integer()
  def color(theme, name), do: Map.get(theme.palette, name, theme.palette["fg"])

  # ── rows ──

  @doc """
  The rows for one session entry. `key` prefixes the row ids (stable across
  re-renders); `owner` is the screen pid that gets each row's long press
  (`{:long_press, {:copy, key}}`) and each code block's Copy tap
  (`{:tap, {:copy_code, key, n}}`).
  """
  @spec entry_rows(map(), String.t(), pid() | nil, map()) :: [map()]
  def entry_rows(entry, key, owner, theme \\ theme()) do
    entry |> entry_lines(theme) |> to_rows(key, owner, theme)
  end

  @doc "Rows for assistant text still streaming (only its tail is re-parsed)."
  @spec stream_rows(Operator.Core.Term.Stream.t(), String.t(), pid() | nil, map()) :: [map()]
  def stream_rows(stream, key, owner, theme \\ theme()) do
    stream |> Operator.Core.Term.Stream.lines() |> markdown(theme) |> to_rows(key, owner, theme)
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
  def plain_text(_entry), do: ""

  @doc """
  The rendered text of rows, one string per row: what the user sees, for
  tests and diagnostics.
  """
  @spec rows_text([map()]) :: [String.t()]
  def rows_text(rows),
    do:
      Enum.map(rows, fn r ->
        r.children |> Enum.map_join("", & &1.props.text) |> String.replace(@nbsp, " ")
      end)

  # An entry → render lines: {:line, segs} | {:code, segs} | {:fence, lang, n}.
  defp entry_lines(%{"type" => "message", "message" => %{"role" => "user"} = m}, theme),
    do: prefixed(Session.text(m["content"]), theme.roles.user)

  defp entry_lines(%{"type" => "message", "message" => %{"role" => "assistant"} = m}, theme) do
    thinking =
      case Session.thinking(m) do
        "" ->
          []

        t ->
          t
          |> clip(theme.thinking_lines, theme.max_line_chars)
          |> Enum.map(&{:line, [{&1, theme.roles.thinking}]})
      end

    text =
      case Session.text(m["content"]) do
        "" -> []
        md -> md |> Markup.parse() |> markdown(theme)
      end

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
    thinking ++ text ++ calls ++ errors
  end

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

  defp entry_lines(_entry, _theme), do: []

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
  # out together (columns padded to the widest cell, monospace).
  defp markdown(lines, theme) do
    {out, _blocks} =
      lines
      |> Enum.chunk_by(&table_line?/1)
      |> Enum.flat_map_reduce(0, fn
        [first | _] = chunk, n ->
          if table_line?(first), do: {table(chunk, theme), n}, else: md_lines(chunk, n, theme)
      end)

    out
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

  defp to_rows(lines, key, owner, theme) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {{:fence, lang, n}, i} ->
        label = {"─ " <> if(lang == "", do: "code", else: lang) <> " ", theme.markup.code_header}
        copy = {" Copy ", theme.markup.copy, owner && {owner, {:copy_code, key, n}}}
        row([label, copy], "#{key}.#{i}", owner, key, theme, theme.markup.code_header)

      {{:code, segs}, i} ->
        row(segs, "#{key}.#{i}", owner, key, theme, theme.markup.code_block)

      {{:line, segs}, i} ->
        row(segs, "#{key}.#{i}", owner, key, theme)
    end)
  end

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
      font: :term,
      text_size: theme.text_size,
      line_height: theme.line_height,
      text_color: color(theme, style[:color] || "fg")
    }

    props = if style[:bold], do: Map.put(props, :font_weight, "bold"), else: props
    props = if style[:italic], do: Map.put(props, :italic, true), else: props

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
