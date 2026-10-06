defmodule Operator.TermUI do
  @moduledoc """
  The terminal look for Operator's own screens (the back): the transcript's
  monospace `:term` font and `Operator.Core.Term` palette, as bars, text,
  `[command]` links, chips and fields. `Operator.ChatScreen` draws its
  chrome with it, `Operator.MenuScreen` and `Operator.DiagnosticsScreen`
  their whole page (`page/4`).

  Every terminal screen's top bar starts with `[frontend]` (`top_bar/2`),
  which sends `{:tap, Operator.Toggle.tag()}`: the screen answers with
  `Operator.Toggle.to_front/1`. Taps go to the calling process (`self()`),
  so call these from the screen's `render/1`.
  """

  alias Operator.Core.Term
  alias Operator.Toggle

  @doc "A bar row (the chat's header, footer and composer), children in a line."
  @spec bar_row(map(), [map()]) :: map()
  def bar_row(t, children) do
    %{
      type: :row,
      props: %{
        fill_width: true,
        padding: 6,
        gap: 6,
        background: Term.color(t, "bar"),
        align: :center
      },
      children: children
    }
  end

  @doc "A terminal screen's top bar: `[frontend]`, then `children`."
  @spec top_bar(map(), [map()]) :: map()
  def top_bar(t, children), do: bar_row(t, [link("frontend", Toggle.tag(), t) | children])

  @doc "A titled top bar for a terminal screen drawn with mob's theme (rescue, QR scan)."
  @spec title_bar(String.t()) :: map()
  def title_bar(title) do
    t = Term.theme()
    top_bar(t, [text(title, t, "heading", font: :term_bold, weight: 1, max_lines: 1)])
  end

  @doc "Monospace text in palette colour `color`; `opts` are more `:text` props."
  @spec text(String.t(), map(), String.t(), keyword()) :: map()
  def text(text, t, color, opts \\ []) do
    props =
      Map.merge(
        %{text: text, font: :term, text_size: t.text_size, text_color: Term.color(t, color)},
        Map.new(opts)
      )

    %{type: :text, props: props, children: []}
  end

  @doc "A command in brackets, `[label]`, tapped like a terminal link: `{:tap, tag}`."
  @spec link(String.t(), term(), map(), keyword()) :: map()
  def link(label, tag, t, opts \\ []) do
    text(
      "[#{label}]",
      t,
      Keyword.get(opts, :color, "accent"),
      Keyword.merge(
        [on_tap: {self(), tag}, padding: 6, accessibility_role: "button"],
        Keyword.delete(opts, :color)
      )
    )
  end

  @doc "A small button on the code background (Send, Stop, approve, save)."
  @spec chip(String.t(), term(), map(), String.t()) :: map()
  def chip(label, tag, t, color \\ "fg") do
    %{
      type: :button,
      props: %{
        text: label,
        on_tap: {self(), tag},
        font: :term,
        text_size: t.text_size - 1,
        text_color: Term.color(t, color),
        background: Term.color(t, "code_bg"),
        padding: 6,
        fill_width: false
      },
      children: []
    }
  end

  @doc "A text field on the code background; `on_change` sends `{:change, tag, value}`."
  @spec field(String.t() | nil, String.t(), term(), map(), keyword()) :: map()
  def field(value, placeholder, tag, t, opts \\ []) do
    props =
      Map.merge(
        %{
          value: value,
          placeholder: placeholder,
          on_change: {self(), tag},
          font: :term,
          text_size: t.text_size,
          text_color: Term.color(t, "fg"),
          placeholder_color: Term.color(t, "dim"),
          background: Term.color(t, "code_bg"),
          border_color: Term.color(t, "code_bg")
        },
        Map.new(opts)
      )

    %{type: :text_field, props: props, children: []}
  end

  @doc """
  A whole terminal page: the top bar (`[frontend]`, `title`, `[back]`, which
  sends `{:tap, :back}`), then `rows` in a scroll on the terminal background.
  """
  @spec page(map(), String.t(), [map()]) :: map()
  def page(t, title, rows) do
    bg = Term.color(t, "bg")

    %{
      type: :column,
      props: %{fill_width: true, fill_height: true, background: bg},
      children: [
        top_bar(t, [
          text(title, t, "heading", font: :term_bold, weight: 1, max_lines: 1),
          link("back", :back, t)
        ]),
        %{
          type: :scroll,
          props: %{weight: 1, fill_width: true, background: bg},
          children: [
            %{
              type: :column,
              props: %{fill_width: true, padding: 12, gap: 2, background: bg},
              children: rows
            }
          ]
        }
      ]
    }
  end

  @heading_width 36

  @doc "A section heading, `── label ───`, #{@heading_width} characters wide (fits a phone)."
  @spec heading(String.t(), map()) :: map()
  def heading(label, t) do
    head = "── #{label} "
    rule = String.duplicate("─", max(@heading_width - String.length(head), 3))
    text(head <> rule, t, "dim", max_lines: 1, padding_top: 14, padding_bottom: 4)
  end

  @doc """
  A menu entry: `label` and a dim `value`, then `›`; a tap anywhere on it
  sends `{:tap, tag}`. `opts`: `:color` (the label's, default `"fg"`),
  `:bold`, `:mark` (a leading `"● "` instead of two spaces).
  """
  @spec item(String.t(), String.t(), term(), map(), keyword()) :: map()
  def item(label, value, tag, t, opts \\ []) do
    lead = if opts[:mark], do: "● ", else: "  "
    font = if opts[:bold], do: :term_bold, else: :term
    color = Keyword.get(opts, :color, "fg")

    %{
      type: :box,
      props: %{
        fill_width: true,
        padding: 8,
        on_tap: {self(), tag},
        accessibility_role: "button"
      },
      children: [
        %{
          type: :row,
          props: %{fill_width: true, gap: 8, align: :center},
          children: [
            # The lead apart from the label, so a wrapped label stays under itself.
            %{
              type: :row,
              props: %{weight: 1, align: :center},
              children: [
                text(lead, t, color, font: font, max_lines: 1),
                text(label, t, color, font: font, weight: 1, max_lines: 2)
              ]
            },
            text(value, t, "dim", max_lines: 1, text_size: t.text_size - 1),
            text("›", t, "dim")
          ]
        }
      ]
    }
  end

  # Where an entry's label starts: the entry's padding plus its two-column lead.
  @indent 24

  @doc "A plain line of the page, wrapping under itself, aligned with the entries' labels."
  @spec line(String.t(), map(), String.t(), keyword()) :: map()
  def line(text, t, color \\ "fg", opts \\ []),
    do: text(text, t, color, Keyword.merge([padding_left: @indent, padding_right: 8], opts))

  @doc "A row of `[command]` links (and chips or fields), aligned with the entries' labels."
  @spec actions(map(), [map()]) :: map()
  def actions(_t, children) do
    %{
      type: :row,
      # A link's own padding (6) makes up the rest of the indent.
      props: %{fill_width: true, gap: 8, align: :center, padding_left: @indent - 6},
      children: children
    }
  end
end
