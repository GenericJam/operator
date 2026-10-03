defmodule Operator.Core.Term.Markup do
  @moduledoc """
  The Markdown the terminal renders: the GitHub-flavoured subset omp's
  terminal renders too (`pi-tui/src/components/markdown.ts`), so a session
  reads the same on the phone and in omp. Blocks: headings, paragraphs,
  fenced code (``` or ~~~, with a language), `-`/`*`/`+` and `1.` lists
  (task boxes too), `>` quotes, `---` rules, pipe tables, `$$` math.
  Inline: `**strong**` / `__strong__`, `*em*` / `_em_`, `~~del~~`,
  `` `code` ``, `[links](url)`, `<autolinks>` and bare URLs, `![images](…)`,
  `$math$`, HTML entities, and the HTML tags models use (`<br>`, `<code>`,
  `<b>`/`<strong>`, `<i>`/`<em>`; every other tag is dropped, its text kept).

  Anything else degrades to readable text, never to raw markup: an
  unmatched `**` / `__` / `~~` is dropped (so a reply still streaming shows
  `**bol` as plain `bol` until the closing `**` arrives), a lone `*` stays
  (it's usually arithmetic).

  Parsing is per line (the terminal shows lines, not reflowed paragraphs)
  and incremental: `push/2` adds one line to a reversed list of parsed
  lines, so a streamed reply only parses each finished line once.

  Lines:

    * `:blank`, `:hr`, `:table_sep`, `:math_delim`, `:fence_close`
    * `{:para, segments, raw}`, `{:heading, level, segments}`,
      `{:item, indent, marker, segments}`, `{:quote, depth, segments}`
    * `{:fence_open, lang}`, `{:code, text}`, `{:math, text}`
    * `{:table_row, [cell_text]}` (cells already inline-stripped to text)

  `segments` are `[{text, styles} | :br]`, `styles` a sorted list of
  `:bold`, `:italic`, `:del`, `:code`, `:math`, `:link`, `:url`.
  """

  @type style :: :bold | :italic | :del | :code | :math | :link | :url
  @type segment :: {String.t(), [style()]} | :br
  @type line :: atom() | tuple()
  @type state :: %{fence: String.t() | nil, math: boolean(), table: boolean()}

  @spec initial() :: {[line()], state()}
  def initial, do: {[], %{fence: nil, math: false, table: false}}

  @spec parse(String.t()) :: [line()]
  def parse(text) do
    {rev, _state} = text |> String.split("\n") |> Enum.reduce(initial(), &push/2)
    Enum.reverse(rev)
  end

  @doc "Parses one more line onto `{reversed_lines, state}`."
  @spec push(String.t(), {[line()], state()}) :: {[line()], state()}
  def push(line, {rev, %{fence: fence} = st}) when is_binary(fence) do
    if String.starts_with?(String.trim_leading(line), fence),
      do: {[:fence_close | rev], %{st | fence: nil}},
      else: {[{:code, line} | rev], st}
  end

  def push(line, {rev, %{math: true} = st}) do
    case String.trim(line) do
      "$$" -> {[:math_delim | rev], %{st | math: false}}
      _ -> {[{:math, line} | rev], st}
    end
  end

  def push(line, {rev, st}) do
    trimmed = String.trim(line)

    cond do
      fence = Regex.run(~r/^(`{3,}|~{3,})\s*([^`\s]*)/, String.trim_leading(line)) ->
        [_, marker, lang] = fence
        {[{:fence_open, lang} | rev], %{st | fence: marker, table: false}}

      trimmed == "$$" ->
        {[:math_delim | rev], %{st | math: true, table: false}}

      table_sep?(trimmed) and table_header?(rev) ->
        {[:table_sep | header_row(rev)], %{st | table: true}}

      (st.table and String.contains?(trimmed, "|")) or Regex.match?(~r/^\|.*\|$/, trimmed) ->
        {[{:table_row, cells(trimmed)} | rev], st}

      true ->
        {[content_line(line, trimmed) | rev], %{st | table: false}}
    end
  end

  defp content_line(_line, ""), do: :blank

  defp content_line(line, _trimmed) do
    cond do
      math = Regex.run(~r/^\$\$(.+)\$\$$/, String.trim(line)) ->
        {:math, Enum.at(math, 1)}

      Regex.match?(~r/^ {0,3}([-*_])( *\1){2,} *$/, line) ->
        :hr

      h = Regex.run(~r/^ {0,3}(\#{1,6})\s+(.*?)(\s+#+)?\s*$/, line) ->
        [_, hashes, text | _] = h
        {:heading, byte_size(hashes), inline(text)}

      q = Regex.run(~r/^\s*((?:>\s?)+)(.*)$/, line) ->
        [_, marks, text] = q
        {:quote, marks |> String.replace(~r/[^>]/, "") |> String.length(), inline(text)}

      li = Regex.run(~r/^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/, line) ->
        [_, indent, marker, text] = li
        {marker, text} = item_marker(marker, text)
        {:item, indent, marker, inline(text)}

      true ->
        {:para, inline(line), line}
    end
  end

  defp item_marker(m, text) when m in ["-", "*", "+"] do
    case text do
      "[ ] " <> rest -> {"☐", rest}
      "[x] " <> rest -> {"☑", rest}
      "[X] " <> rest -> {"☑", rest}
      _ -> {"•", text}
    end
  end

  defp item_marker(m, text), do: {m, text}

  defp table_sep?(trimmed),
    do:
      String.contains?(trimmed, "|") and
        Regex.match?(~r/^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/, trimmed)

  defp table_header?([{:table_row, _} | _]), do: true
  defp table_header?([{:para, _, raw} | _]), do: String.contains?(raw, "|")
  defp table_header?(_), do: false

  defp header_row([{:para, _, raw} | rest]), do: [{:table_row, cells(String.trim(raw))} | rest]
  defp header_row(rev), do: rev

  defp cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&(&1 |> String.trim() |> String.replace("\\|", "|") |> inline() |> seg_text()))
  end

  # ── plain text ──

  @doc """
  A message's plain text for the clipboard: markup stripped, code and math
  verbatim, fence lines dropped, links as `text (url)`.
  """
  @spec plain(String.t()) :: String.t()
  def plain(text) do
    text
    |> parse()
    |> Enum.flat_map(fn
      :blank -> [""]
      :hr -> ["---"]
      {:para, segs, _} -> [seg_text(segs)]
      {:heading, _, segs} -> [seg_text(segs)]
      {:item, indent, marker, segs} -> [indent <> plain_marker(marker) <> " " <> seg_text(segs)]
      {:quote, depth, segs} -> [String.duplicate("> ", depth) <> seg_text(segs)]
      {:code, line} -> [line]
      {:math, line} -> [line]
      {:table_row, cells} -> [Enum.join(cells, " | ")]
      _delimiter -> []
    end)
    |> Enum.join("\n")
  end

  defp plain_marker("•"), do: "-"
  defp plain_marker(m), do: m

  @doc "The verbatim text of the `n`th (0-based) fenced code block, or nil."
  @spec code_block(String.t(), non_neg_integer()) :: String.t() | nil
  def code_block(text, n) do
    blocks =
      text
      |> parse()
      |> Enum.reduce({[], nil}, fn
        {:fence_open, _}, {done, _} -> {done, []}
        :fence_close, {done, lines} when is_list(lines) -> {[Enum.reverse(lines) | done], nil}
        {:code, line}, {done, lines} when is_list(lines) -> {done, [line | lines]}
        _, acc -> acc
      end)
      |> then(fn
        {done, nil} -> done
        {done, open} -> [Enum.reverse(open) | done]
      end)
      |> Enum.reverse()

    case Enum.at(blocks, n) do
      nil -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  @doc "The text of segments (`:br` as a newline)."
  @spec seg_text([segment()]) :: String.t()
  def seg_text(segs),
    do:
      Enum.map_join(segs, "", fn
        {t, _} -> t
        :br -> "\n"
      end)

  # ── inline ──

  @doc "Inline markup of one line → merged styled segments."
  @spec inline(String.t()) :: [segment()]
  def inline(text) do
    text |> tokenize([], []) |> pair() |> segments([], []) |> merge()
  end

  # Tokens: {:text, s} | {:code, s} | {:math, s} | {:link, text, url} | :br
  #         | {:mark, kind, can_open, can_close, raw}

  @entities %{
    "nbsp" => " ",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "amp" => "&"
  }
  @html_marks %{
    "b" => :bold,
    "strong" => :bold,
    "i" => :italic,
    "em" => :italic,
    "code" => :code_tag,
    "del" => :del,
    "s" => :del
  }

  defp tokenize(<<>>, buf, acc), do: Enum.reverse(flush(buf, acc))

  defp tokenize(<<"\\", c::utf8, rest::binary>>, buf, acc) when c in ~c"\\`*_{}[]()#+-.!|~$<>&",
    do: tokenize(rest, [<<c::utf8>> | buf], acc)

  defp tokenize(<<"`", _::binary>> = text, buf, acc) do
    [ticks] = Regex.run(~r/^`+/, text)
    rest = binary_part(text, byte_size(ticks), byte_size(text) - byte_size(ticks))

    case :binary.split(rest, ticks) do
      [code, after_code] when code != "" ->
        tokenize(after_code, [], [{:code, String.trim(code)} | flush(buf, acc)])

      _ ->
        tokenize(rest, [ticks | buf], acc)
    end
  end

  defp tokenize(<<"**", rest::binary>>, buf, acc), do: mark(:bold, "**", rest, buf, acc)
  defp tokenize(<<"__", rest::binary>>, buf, acc), do: mark(:bold_u, "__", rest, buf, acc)
  defp tokenize(<<"~~", rest::binary>>, buf, acc), do: mark(:del, "~~", rest, buf, acc)
  defp tokenize(<<"*", rest::binary>>, buf, acc), do: mark(:italic, "*", rest, buf, acc)
  defp tokenize(<<"_", rest::binary>>, buf, acc), do: mark(:italic_u, "_", rest, buf, acc)

  defp tokenize(<<"![", _::binary>> = text, buf, acc) do
    case Regex.run(~r/^!\[([^\]]*)\]\(([^)\s]*)[^)]*\)/, text) do
      [whole, alt, _url] ->
        tokenize(drop(text, whole), [], [{:text, "[image: #{alt}]"} | flush(buf, acc)])

      nil ->
        tokenize(drop(text, "!"), ["!" | buf], acc)
    end
  end

  defp tokenize(<<"[", _::binary>> = text, buf, acc) do
    case Regex.run(~r/^\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, text) do
      [whole, label, url] ->
        tokenize(drop(text, whole), [], [{:link, label, url} | flush(buf, acc)])

      nil ->
        tokenize(drop(text, "["), ["[" | buf], acc)
    end
  end

  defp tokenize(<<"<", _::binary>> = text, buf, acc) do
    cond do
      auto = Regex.run(~r/^<((?:https?|mailto):[^>\s]+)>/, text) ->
        [whole, url] = auto
        tokenize(drop(text, whole), [], [{:link, url, url} | flush(buf, acc)])

      tag = Regex.run(~r/^<(\/?)([a-zA-Z][a-zA-Z0-9]*)\b[^<>]*?(\/?)>/, text) ->
        [whole, closing, name, _self] = tag

        tokenize(
          drop(text, whole),
          [],
          html_token(String.downcase(name), closing == "/") ++ flush(buf, acc)
        )

      true ->
        tokenize(drop(text, "<"), ["<" | buf], acc)
    end
  end

  defp tokenize(<<"&", _::binary>> = text, buf, acc) do
    case Regex.run(~r/^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-z]+);/, text) do
      [whole, name] ->
        case entity(name) do
          nil -> tokenize(drop(text, "&"), ["&" | buf], acc)
          char -> tokenize(drop(text, whole), [char | buf], acc)
        end

      nil ->
        tokenize(drop(text, "&"), ["&" | buf], acc)
    end
  end

  defp tokenize(<<"$", _::binary>> = text, buf, acc) do
    cond do
      block = Regex.run(~r/^\$\$(.+?)\$\$/, text) ->
        [whole, body] = block
        tokenize(drop(text, whole), [], [{:math, String.trim(body)} | flush(buf, acc)])

      # pandoc's rule: no space inside the dollars, no digit right after the
      # closing one ("$5 and $10" is money, not math)
      span = Regex.run(~r/^\$([^\s$](?:[^$]*[^\s$])?)\$(?![0-9])/, text) ->
        [whole, body] = span
        tokenize(drop(text, whole), [], [{:math, body} | flush(buf, acc)])

      true ->
        tokenize(drop(text, "$"), ["$" | buf], acc)
    end
  end

  defp tokenize(<<"http", _::binary>> = text, buf, acc) do
    case prev_char(buf, acc) |> word_char?() do
      false ->
        case Regex.run(~r/^https?:\/\/[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]/, text) do
          [url] -> tokenize(drop(text, url), [], [{:link, url, url} | flush(buf, acc)])
          nil -> tokenize(drop(text, "h"), ["h" | buf], acc)
        end

      true ->
        tokenize(drop(text, "h"), ["h" | buf], acc)
    end
  end

  defp tokenize(<<c::utf8, rest::binary>>, buf, acc), do: tokenize(rest, [<<c::utf8>> | buf], acc)

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp html_token("br", _closing), do: [:br]

  defp html_token(name, closing) do
    case @html_marks do
      %{^name => kind} -> [{:mark, kind, not closing, closing, ""}]
      _ -> []
    end
  end

  defp entity("#x" <> hex), do: codepoint(String.to_integer(hex, 16))
  defp entity("#X" <> hex), do: codepoint(String.to_integer(hex, 16))
  defp entity("#" <> dec), do: codepoint(String.to_integer(dec))
  defp entity(name), do: Map.get(@entities, name)

  defp codepoint(n) when n in 1..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp codepoint(_), do: nil

  defp mark(kind, raw, rest, buf, acc) do
    prev = prev_char(buf, acc)
    next = String.first(rest)
    can_open = next != nil and not space?(next)
    can_close = prev != nil and not space?(prev)

    # `_` / `__` don't work inside words (snake_case stays as it is)
    {can_open, can_close} =
      if kind in [:italic_u, :bold_u],
        do: {can_open and not word_char?(prev), can_close and not word_char?(next)},
        else: {can_open, can_close}

    tokenize(rest, [], [{:mark, kind, can_open, can_close, raw} | flush(buf, acc)])
  end

  # The character before a marker: the text buffered so far, else the
  # previous token (a code span or link counts as a word; a marker as nothing).
  defp prev_char([c | _], _acc), do: c
  defp prev_char([], [{:text, t} | _]), do: String.last(t)
  defp prev_char([], [{kind, _} | _]) when kind in [:code, :math], do: "`"
  defp prev_char([], [{:link, _, _} | _]), do: "a"
  defp prev_char([], _acc), do: nil

  defp space?(char), do: char in [" ", "\t"]

  defp word_char?(nil), do: false
  defp word_char?(c), do: Regex.match?(~r/^[\p{L}\p{N}]$/u, c)

  defp flush([], acc), do: acc
  defp flush(buf, acc), do: [{:text, buf |> Enum.reverse() |> IO.iodata_to_binary()} | acc]

  # ── pairing: matched markers become {:on | :off, style} ──

  defp pair(tokens) do
    indexed = Enum.with_index(tokens)

    {matches, _stack} =
      Enum.reduce(indexed, {%{}, []}, fn
        {{:mark, kind, can_open, can_close, _}, i}, {m, stack} ->
          case can_close && pop_to(stack, kind) do
            {opener, rest} ->
              {Map.merge(m, %{opener => {:on, style(kind)}, i => {:off, style(kind)}}), rest}

            _ when can_open ->
              {m, [{kind, i} | stack]}

            _ ->
              {m, stack}
          end

        _, acc ->
          acc
      end)

    Enum.map(indexed, fn {token, i} ->
      case matches do
        %{^i => match} -> match
        _ -> unmatched(token)
      end
    end)
  end

  defp style(kind) when kind in [:bold, :bold_u], do: :bold
  defp style(kind) when kind in [:italic, :italic_u], do: :italic
  defp style(:code_tag), do: :code
  defp style(:del), do: :del

  defp pop_to(stack, kind) do
    case Enum.split_while(stack, fn {k, _} -> k != kind end) do
      {_above, [{^kind, i} | rest]} -> {i, rest}
      _ -> nil
    end
  end

  # A single `*` / `_` that pairs with nothing is ordinary text; doubled
  # markers and HTML tags that pair with nothing are dropped.
  defp unmatched({:mark, kind, _, _, raw}) when kind in [:italic, :italic_u], do: {:text, raw}
  defp unmatched({:mark, _, _, _, _}), do: {:text, ""}
  defp unmatched(token), do: token

  # ── segments ──

  defp segments([], _active, acc), do: Enum.reverse(acc)
  defp segments([{:on, style} | rest], active, acc), do: segments(rest, [style | active], acc)

  defp segments([{:off, style} | rest], active, acc),
    do: segments(rest, List.delete(active, style), acc)

  defp segments([:br | rest], active, acc), do: segments(rest, active, [:br | acc])
  defp segments([{:text, ""} | rest], active, acc), do: segments(rest, active, acc)

  defp segments([{:text, t} | rest], active, acc),
    do: segments(rest, active, [{t, styles(active)} | acc])

  defp segments([{:code, t} | rest], active, acc),
    do: segments(rest, active, [{t, styles([:code | active])} | acc])

  defp segments([{:math, t} | rest], active, acc),
    do: segments(rest, active, [{t, styles([:math | active])} | acc])

  defp segments([{:link, label, url} | rest], active, acc) do
    label_seg = {label, styles([:link | active])}
    acc = if label == url, do: [label_seg | acc], else: [{" (#{url})", [:url]}, label_seg | acc]
    segments(rest, active, acc)
  end

  defp styles(active), do: active |> Enum.uniq() |> Enum.sort()

  defp merge([{a, s}, {b, s} | rest]), do: merge([{a <> b, s} | rest])
  defp merge([seg | rest]), do: [seg | merge(rest)]
  defp merge([]), do: []
end
