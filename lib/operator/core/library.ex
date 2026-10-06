defmodule Operator.Core.Library.Pages do
  @moduledoc false
  # Parsing and rendering for `Operator.Core.Library`, which runs them at
  # compile time: a module can't call its own functions while it compiles.

  @dirs [{"showcase/components/", :component}, {"showcase/phone/", :phone}]
  # The section's budget in bytes, and the shapes tried to keep under it,
  # widest first: {usage line cap, props per line}.
  @budget 6_000
  @shapes for cap <- [90, 80, 72, 64, 56, 48, 40], props <- [4, 3, 2], do: {cap, props}
  @usage_cap 90
  # Layout tags a usage line never starts at, when a page has no Mishka tag.
  @layout ~w(Column Row Box Scroll Text Spacer Divider)

  def budget, do: @budget
  def usage_cap, do: @usage_cap

  def parse(sources) do
    for {path, source} <- sources,
        kind = kind(path),
        kind != nil,
        entry = page(kind, path, source),
        entry != nil do
      entry
    end
    |> Enum.sort_by(&{&1.kind, &1.category || "", &1.order, &1.name})
  end

  defp kind(path) do
    Enum.find_value(@dirs, fn {dir, kind} -> if page_in?(path, dir), do: kind end)
  end

  # Directly in `dir`, not in a subdirectory of it.
  defp page_in?(path, dir) do
    file = String.replace_prefix(path, dir, "")
    file != path and String.ends_with?(file, ".ex") and not String.contains?(file, "/")
  end

  # ── parsing ──

  defp page(kind, path, source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         %{} = entry <- literal_map(def_body(ast, :entry)) do
      codes = codes(def_body(ast, :examples)) ++ codes(ast)
      {tag, usage} = usage(codes, mishka_aliases(ast), path)

      %{
        kind: kind,
        name: to_string(entry[:name] || Path.basename(path, ".ex")),
        path: path,
        category: string_or_nil(entry[:category]),
        order: if(is_number(entry[:order]), do: entry[:order], else: 0),
        tag: tag,
        props: props(def_body(ast, :props)),
        usage: usage,
        api: string_or_nil(entry[:api])
      }
    else
      _ -> nil
    end
  end

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  # The body of the module's zero-arity `def name`, or nil.
  defp def_body(ast, name) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{^name, _, args}, [do: body]]} = node, nil when args in [nil, []] ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # A map literal's literal pairs (strings, atoms, numbers).
  defp literal_map({:%{}, _, pairs}) when is_list(pairs) do
    for {k, v} <- pairs, is_atom(k), is_binary(v) or is_atom(v) or is_number(v), into: %{} do
      {k, v}
    end
  end

  defp literal_map(_), do: nil

  # The Mishka components the page aliases, in order.
  defp mishka_aliases(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:alias, _, [{:__aliases__, _, [:MobMishka, :Components, name]} | _]} = node, acc ->
          {node, [name | acc]}

        {:alias, _, [{{:., _, [{:__aliases__, _, [:MobMishka, :Components]}, :{}]}, _, list}]} =
            node,
        acc ->
          {node, Enum.reverse(for({:__aliases__, _, [name]} <- list, do: name), acc)}

        node, acc ->
          {node, acc}
      end)

    names |> Enum.reverse() |> Enum.map(&Atom.to_string/1)
  end

  # The `~S` example code under `ast`, in source order.
  defp codes(nil), do: []

  defp codes(ast) do
    {_, codes} =
      Macro.prewalk(ast, [], fn
        {:sigil_S, _, [{:<<>>, _, [code]}, _]} = node, acc when is_binary(code) ->
          {node, [code | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(codes)
  end

  # Prop names, helpers (`snap/2`) and slots (`<:item>`) left out.
  defp props(nil), do: []

  defp props(body) do
    {_, names} =
      Macro.prewalk(body, [], fn
        {:%{}, _, pairs} = node, acc when is_list(pairs) -> {node, prop_name(pairs, acc)}
        node, acc -> {node, acc}
      end)

    names |> Enum.reverse() |> Enum.uniq()
  end

  defp prop_name(pairs, acc) do
    name = Keyword.get(pairs, :name)

    if is_binary(name) and Keyword.get(pairs, :type) != "helper" and name =~ ~r/^[a-z0-9_?]+$/,
      do: [name | acc],
      else: acc
  end

  # The page's widget and the first opening tag of it in the examples'
  # code, on one line. The widget is the Mishka one named after the file,
  # else the first aliased one used, else the first Mishka-like tag, else
  # the first capitalised tag that isn't a layout one.
  defp usage(codes, aliases, path) do
    own = "Mishka" <> Macro.camelize(Path.basename(path, ".ex"))

    starts =
      Enum.map(Enum.uniq([own | aliases]), &~r/<#{&1}(?![\w.])/) ++
        [~r/<Mishka[A-Z]\w*/, ~r/<(?!(?:#{Enum.join(@layout, "|")})(?![\w.]))[A-Z]\w*/]

    Enum.find_value(starts, {List.first(aliases), nil}, fn start ->
      Enum.find_value(codes, &first_tag(&1, start))
    end)
  end

  defp first_tag(code, start) do
    with [{at, _}] <- Regex.run(start, code, return: :index) do
      {["<" <> tag | _] = parts, closer} =
        opening_tag(binary_part(code, at, byte_size(code) - at))

      {tag, Enum.join(parts, " ") <> " " <> closer}
    end
  end

  # The text up to the `>` closing the opening tag (outside {…} and "…"),
  # as {[name | attributes], closer}.
  defp opening_tag(text), do: scan(text, 0, false, [""])

  defp scan(<<">", _::binary>>, 0, false, toks), do: finish(toks, ">")
  defp scan(<<"/>", _::binary>>, 0, false, toks), do: finish(toks, "/>")
  defp scan(<<"\"", r::binary>>, d, q, [cur | t]), do: scan(r, d, not q, [cur <> "\"" | t])
  defp scan(<<"{", r::binary>>, d, false, [cur | t]), do: scan(r, d + 1, false, [cur <> "{" | t])

  defp scan(<<"}", r::binary>>, d, false, [cur | t]),
    do: scan(r, max(d - 1, 0), false, [cur <> "}" | t])

  defp scan(<<c::utf8, r::binary>>, 0, false, toks) when c in [?\s, ?\n, ?\t, ?\r] do
    case toks do
      ["" | _] -> scan(r, 0, false, toks)
      _ -> scan(r, 0, false, ["" | toks])
    end
  end

  defp scan(<<c::utf8, r::binary>>, d, q, [cur | t]) when c in [?\n, ?\r, ?\t],
    do: scan(r, d, q, [cur <> " " | t])

  defp scan(<<c::utf8, r::binary>>, d, q, [cur | t]), do: scan(r, d, q, [cur <> <<c::utf8>> | t])
  defp scan(<<>>, _d, _q, toks), do: finish(toks, ">")

  defp finish(toks, closer), do: {toks |> Enum.reject(&(&1 == "")) |> Enum.reverse(), closer}

  # ── rendering ──

  # The widest shape that fits the budget (the narrowest if none does).
  def render(entries) do
    Enum.find_value(@shapes, fn shape ->
      text = render(entries, shape)
      if byte_size(text) <= @budget, do: text
    end) || render(entries, List.last(@shapes))
  end

  defp render(entries, shape) do
    {components, phone} = Enum.split_with(entries, &(&1.kind == :component))

    """
    ## The component library

    The front's library (menu › components) has a worked page per widget below. `dyn_read` \
    its file before you use a widget; `dyn_copy` it to start a screen from it.
    """ <> components_section(components, shape) <> phone_section(phone)
  end

  defp components_section([], _shape), do: ""

  defp components_section(entries, shape) do
    "\nMishka widgets, in showcase/components/ (file, usage, +more props):\n" <>
      (entries
       |> Enum.chunk_by(& &1.category)
       |> Enum.map_join(fn [%{category: category} | _] = group ->
         "#{category || "Other"}:\n" <> Enum.map_join(group, &component_line(&1, shape))
       end))
  end

  defp component_line(e, {cap, max_props}) do
    usage = if e.usage, do: e.usage |> opening_tag() |> cap(cap), else: e.tag && "<#{e.tag}>"
    name = if usage && named?(e), do: "", else: e.name <> " "

    extra =
      e.props
      |> Enum.reject(&(usage && String.contains?(usage, " " <> &1 <> "=")))
      |> Enum.take(max_props)

    props = if extra == [], do: "", else: " +" <> Enum.join(extra, " ")
    "- #{Path.basename(e.path)} #{name}#{usage}#{props}\n"
  end

  # Does the tag already say the name (MishkaColorSwatch, Color swatch)?
  defp named?(%{tag: nil}), do: false

  defp named?(e),
    do: String.downcase(e.tag) == String.downcase("Mishka" <> String.replace(e.name, " ", ""))

  # The whole opening tag, or as many attributes as fit in `cap`
  # characters, then `…`.
  defp cap({[name | attrs], closer}, cap) do
    full = Enum.join([name | attrs], " ") <> " " <> closer
    if String.length(full) <= cap, do: full, else: cut(name, attrs, " … " <> closer, cap)
  end

  defp cut(acc, [attr | attrs], tail, cap) do
    next = acc <> " " <> attr
    if String.length(next <> tail) <= cap, do: cut(next, attrs, tail, cap), else: acc <> tail
  end

  defp cut(acc, [], tail, _cap), do: acc <> tail

  defp phone_section([]), do: ""

  defp phone_section(entries) do
    "\nPhone widgets, in showcase/phone/ (file, name, the APIs it uses):\n" <>
      Enum.map_join(entries, fn e ->
        api = if e.api, do: " (#{e.api})", else: ""
        "- #{Path.basename(e.path)} #{e.name}#{api}\n"
      end)
  end
end

defmodule Operator.Core.Library do
  @moduledoc """
  The component library's catalogue, for the system prompt: one line per
  widget page of the seed (`showcase/components/*.ex`, the Mishka widgets,
  and `showcase/phone/*.ex`, the phone capability widgets), so the agent
  knows what exists and where before it writes a screen.

  It is built at compile time from `Operator.Core.Dyn.Seed.sources/0`, by
  parsing each page (never running it), so it can't drift from the library.
  A page gives its `entry/0` map, its Mishka alias (the tag), the names of
  its `props/0` and the opening tag of its first example: the usage line.
  A page without examples or props still gets its line.

  The whole section stays within 6 KB, as it goes into every request:
  each line lists a few more props and cuts its usage at an attribute, and
  the more pages there are, the fewer props and the shorter the usage.
  """

  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Library.Pages

  @typedoc "One library page."
  @type entry :: %{
          kind: :component | :phone,
          name: String.t(),
          path: String.t(),
          category: String.t() | nil,
          order: number(),
          tag: String.t() | nil,
          props: [String.t()],
          usage: String.t() | nil,
          api: String.t() | nil
        }

  @doc "The library's pages, as parsed from `sources`."
  @spec parse(%{String.t() => String.t()}) :: [entry()]
  defdelegate parse(sources), to: Pages

  @doc "The catalogue section for `sources` (see `catalogue/0`)."
  @spec build(%{String.t() => String.t()}) :: String.t()
  def build(sources), do: Pages.render(Pages.parse(sources))

  @entries Pages.parse(Seed.sources())
  @catalogue Pages.render(@entries)

  @doc "The seed's library pages."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The system prompt section listing the seed's library."
  @spec catalogue() :: String.t()
  def catalogue, do: @catalogue

  @doc "The longest usage line a catalogue line carries."
  @spec usage_cap() :: pos_integer()
  def usage_cap, do: Pages.usage_cap()
end
