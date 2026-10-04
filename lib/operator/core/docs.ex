defmodule Operator.Core.Docs do
  @moduledoc """
  The docs the agent reads on the phone, where it has no mob documentation
  otherwise: the guides `mix operator.docs` writes to `priv/docs/` (mob's
  guides, its rules for app code, the Mishka widgets, the capability
  plugins' READMEs), embedded at build time like the Dyn seed
  (`Application.app_dir/2` can't resolve priv/ on the device), and any
  loaded module's docs (`Code.fetch_docs/1`: the device's BEAMs keep their
  Docs chunks). The `read_guide` and `read_doc` tools read them; the system
  prompt lists the guides.
  """

  # Read at compile time and embedded, like Operator.Core.Dyn.Seed.
  # credo:disable-for-next-line
  @dir Path.expand("../../../priv/docs", __DIR__)
  @external_resource Path.join(@dir, "index.md")
  @index (case File.read(Path.join(@dir, "index.md")) do
            {:ok, text} ->
              for line <- String.split(text, "\n"),
                  [name, about] <- [String.split(line, ": ", parts: 2)],
                  not String.starts_with?(name, "<!--"),
                  do: {name, about}

            {:error, _} ->
              []
          end)
  @guides (for {name, _} <- @index, into: %{} do
             path = Path.join(@dir, name <> ".md")
             @external_resource path
             {name, File.read!(path)}
           end)

  @doc "Every guide's name and what it covers, in the index's order."
  @spec index() :: [{String.t(), String.t()}]
  def index, do: @index

  @spec names() :: [String.t()]
  def names, do: Enum.map(@index, &elem(&1, 0))

  @spec guide(String.t()) :: {:ok, String.t()} | :error
  def guide(name), do: Map.fetch(@guides, name)

  @doc """
  The system prompt section on writing app code with mob, and the guide
  index.
  """
  @spec agent_guide() :: String.t()
  def agent_guide do
    """
    ## Building with mob

    Screens and tools are Elixir on mob. You have no other documentation than the guides \
    below and the modules' docs: before using an API, prop, widget or message you haven't \
    used in this session, `read_guide` the relevant guide (a `section` is enough) and \
    `read_doc` the module. Never guess props or message shapes; if a guide and `read_doc` \
    disagree, `read_doc` describes the code this phone runs.

    - A screen: `use Mob.Screen`. `mount(params, session, socket)` seeds every assign \
    `render/1` reads (`{:ok, Mob.Socket.assign(socket, key: value)}`); `render(assigns)` \
    returns a `~MOB` template (`@key` reads an assign; `:if={...}` and `:for={x <- @xs}` \
    attributes) or node maps, every prop (events too) inside `props`: \
    `%{type: :button, props: %{text: "Go", on_tap: {self(), :go}}, children: []}`. \
    `handle_info/2` takes events and ends with a catch-all \
    `def handle_info(_msg, socket), do: {:noreply, socket}`. State is the assigns, in the \
    screen's process; `Mob.State.get/2` and `put/2` keep small values across launches.
    - `~MOB` is a heredoc: `~MOB\"""`, a new line, the tags, `\"""` on a line of its own. One \
    can't hold another (the inner `\"""` ends the outer): use `:if`/`:for`, or build the \
    child first (a variable or a function returning a node) and put it in as `{child}`.
    - Tags (`components`, `styling`): Column, Row, Box, Scroll, List, Text, Button, Spacer, \
    Image, TextField, Toggle, Slider, ... Props: `padding`, `background`, `fill_width`, \
    `fill_height`, `weight`, `text_size` (`:xs`..`:"2xl"` or a number), `text_color`, \
    `corner_radius`. Colours: theme atoms (`:background`, `:surface`, `:on_surface`, \
    `:primary`, `:on_primary`, `:muted`, `:border`, ...) or `0xAARRGGBB`.
    - Events (`events`): `on_tap={{self(), :tag}}` sends `{:tap, :tag}`; inputs' \
    `on_change={{self(), :tag}}` send `{:change, :tag, value}` (the outer braces are `~MOB`'s).
    - Mishka widgets (`mishka`) are tags too, `<MishkaTabs active={@tab} on_change={:pick}>`; \
    they take a bare atom for events and each sends its own shape (MishkaSlider \
    `{:change, tag, float}`, MishkaTabs `{:tap, {tag, tab_id}}`): `read_doc` \
    `MobMishka.Components.Mishka<Name>` for its props and message.
    - Navigation (`navigation`): `Mob.Socket.push_screen(socket, Module, params)`, \
    `pop_screen/1`, `reset_to/2`.
    - Themes (`theming`): `Mob.Theme.set(Mob.Theme.Dark)`, `Mob.Theme.Light`, `MobThemes.*`.
    - Permissions (`permissions`) are asked at first use, never at launch: \
    `Mob.Permissions.request(socket, perm)`; the answer, `{:permission, perm, :granted}` or \
    `{:permission, perm, :denied}`, comes to `handle_info/2` even when already granted: \
    start the capability on `:granted`.
    - Capabilities (each has a guide; `device_capabilities` for `Mob.*`): `MobCamera` \
    (`:camera`), `MobLocation` (`:location`), `MobPhotos` (`:media`), `MobScanner` (`:camera`), \
    `MobNotify` (`:notifications`), `MobBluetooth` (`:bluetooth_connect`), `MobBiometric`, \
    `MobTouch`, `MobVideo`, `MobScreencast`, `Mob.Speech`, `Mob.Haptic`, `Mob.Clipboard`, \
    `Mob.Share`, `Mob.Alert`, `Mob.Device.open_url/1` (browser, `tel:`, `geo:`), `Req` for \
    HTTP. E.g. `MobLocation.get_once(socket)` → `{:location, %{lat: _, lon: _}}` or \
    `{:location, :error, reason}` to `handle_info/2`; read the guide for each call's messages.
    """
  end

  @doc "The system prompt's list of the guides, for `read_guide`."
  @spec guide_index() :: String.t()
  def guide_index do
    """
    ## Guides (`read_guide` name)

    #{Enum.map_join(@index, "\n", fn {name, about} -> "#{name}: #{about}" end)}
    """
  end

  @doc """
  The headings of a guide's text (outside code fences), each `{line
  number, level, title}`.
  """
  @spec headings(String.t()) :: [{pos_integer(), pos_integer(), String.t()}]
  def headings(text) do
    {found, _fence} =
      text
      |> lines()
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, n}, {acc, fence} ->
        case {fence, fence(line), heading(line)} do
          {nil, nil, nil} -> {acc, nil}
          {nil, nil, {level, title}} -> {[{n, level, title} | acc], nil}
          {nil, opened, _} -> {acc, opened}
          {open, closing, _} -> {acc, if(closes?(open, closing), do: nil, else: open)}
        end
      end)

    Enum.reverse(found)
  end

  @doc """
  The section under the first heading `match?` accepts (given its title):
  the heading through the line before the next heading of its level or
  above, or `:error`.
  """
  @spec section(String.t(), (String.t() -> boolean())) :: {:ok, String.t()} | :error
  def section(text, match?) do
    headings = headings(text)

    case Enum.find(headings, fn {_, _, title} -> match?.(title) end) do
      nil ->
        :error

      {line, level, _} ->
        lines = lines(text)
        next = Enum.find(headings, fn {n, l, _} -> n > line and l <= level end)
        last = if next, do: elem(next, 0) - 1, else: length(lines)
        {:ok, lines |> Enum.slice((line - 1)..(last - 1)//1) |> Enum.join("\n")}
    end
  end

  @doc "A text's lines (a final newline ends the last line, it doesn't start another)."
  @spec lines(String.t()) :: [String.t()]
  def lines(text), do: text |> String.trim_trailing("\n") |> String.split("\n")

  defp heading(line) do
    case Regex.run(~r/^ {0,3}(\#{1,6})\s+(.*?)\s*$/, line) do
      [_, hashes, title] -> {String.length(hashes), title}
      nil -> nil
    end
  end

  # A fence line (up to 3 spaces, then 3+ backticks or tildes) as
  # `{char, length}`; a fence closes on the same char, at least as long.
  defp fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_, run] -> {String.first(run), String.length(run)}
      nil -> nil
    end
  end

  defp closes?({char, len}, {char, n}), do: n >= len
  defp closes?(_open, _line), do: false

  @doc """
  A module's moduledoc and its public functions and macros (signature and
  the first paragraph of each doc), or with `function` every arity of it in
  full. `name` is a module as written in Elixir (`Mob.UI`) or an Erlang
  one (`:timer`).
  """
  @spec module_doc(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def module_doc(name, function \\ nil) do
    with {:ok, module} <- module(name),
         {:ok, docs} <- fetch_docs(module, name) do
      render(module, docs, function)
    end
  end

  # No atom is made from a name unless a module by that name is loaded or
  # on the code path (the model's input mustn't fill the atom table).
  defp module(name) do
    name = String.trim(name)

    file =
      cond do
        name =~ ~r/^(Elixir\.)?[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/ ->
          "Elixir." <> String.replace_prefix(name, "Elixir.", "")

        name =~ ~r/^:[a-z][a-z0-9_]*$/ ->
          String.trim_leading(name, ":")

        true ->
          nil
      end

    with false <- is_nil(file),
         module when is_atom(module) <- existing(file),
         true <- Code.ensure_loaded?(module) do
      {:ok, module}
    else
      true ->
        {:error, "#{inspect(name)} isn't a module name (write it like Mob.UI or :timer)"}

      _ ->
        {:error,
         "No module #{name} on this phone. Check the spelling and the namespace " <>
           "(Mob.*, MobLocation, MobMishka.Components.Mishka<Name>, ...); a guide names them."}
    end
  end

  defp existing(file) do
    String.to_existing_atom(file)
  rescue
    ArgumentError ->
      if :code.where_is_file(String.to_charlist(file <> ".beam")) != :non_existing,
        do: String.to_atom(file)
  end

  defp fetch_docs(module, name) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, _} = docs ->
        {:ok, docs}

      _ ->
        hint =
          if String.starts_with?(name, "Operator.Dyn."),
            do: "It's your own Dyn code: dyn_read its source.",
            else: "Its docs were stripped from this build (an over-the-air update does that)."

        {:error, "#{name} has no docs here. #{hint}"}
    end
  end

  # @moduledoc false hides the module's doc, not the functions it documents.
  defp render(module, {:docs_v1, _, _, _, moduledoc, _, entries}, nil) do
    entries = visible(entries)

    intro =
      case moduledoc do
        :hidden -> "(@moduledoc false: internal to its library, not meant for app code)"
        doc -> text(doc) || "(no moduledoc)"
      end

    sections =
      for {kind, title} <- [function: "Functions", macro: "Macros", callback: "Callbacks"],
          listed = for({{^kind, _, _}, _, _, _, _} = e <- entries, do: summary(e)),
          listed != [],
          do: "## #{title}\n\n" <> Enum.join(listed, "\n")

    {:ok,
     Enum.join(
       ["# #{inspect(module)}", intro | sections] ++
         ["(read_doc with `function` gives one function's whole doc.)"],
       "\n\n"
     )}
  end

  defp render(module, {:docs_v1, _, _, _, _, _, entries}, function) do
    case entries |> visible(function) |> Enum.map(&full/1) do
      [] ->
        {:error, "#{inspect(module)} has no public function #{function}."}

      found ->
        {:ok, Enum.join(["# #{inspect(module)}" | found], "\n\n")}
    end
  end

  defp visible(entries, function \\ nil) do
    function = function && to_string(function)

    for {{kind, name, _}, _, _, doc, _} = e <- entries,
        kind in [:function, :macro, :callback, :macrocallback],
        doc != :hidden,
        function == nil or Atom.to_string(name) == function do
      case e do
        {{:macrocallback, n, a}, anno, sigs, d, meta} -> {{:callback, n, a}, anno, sigs, d, meta}
        e -> e
      end
    end
  end

  defp summary({{kind, name, arity}, _, sigs, doc, _}) do
    first =
      case text(doc) do
        nil -> ""
        text -> " — " <> (text |> String.split("\n\n", parts: 2) |> hd() |> one_line())
      end

    "- " <> signature(kind, name, arity, sigs) <> first
  end

  defp full({{kind, name, arity}, _, sigs, doc, _}),
    do: "## " <> signature(kind, name, arity, sigs) <> "\n\n" <> (text(doc) || "(no doc)")

  defp signature(_kind, _name, _arity, [_ | _] = sigs), do: Enum.join(sigs, " / ")
  defp signature(_kind, name, arity, []), do: "#{name}/#{arity}"

  defp one_line(text), do: String.replace(text, ~r/\s*\n\s*/, " ")

  defp text(%{"en" => text}) when is_binary(text), do: text
  defp text(_), do: nil
end
