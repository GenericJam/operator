defmodule Mix.Tasks.Operator.Docs do
  @shortdoc "Refreshes priv/docs, the mob docs the agent reads on the phone"
  @moduledoc """
  Writes `priv/docs/`: the guides the agent on the phone reads with its
  `read_guide` tool (`Operator.Core.Docs`), taken from the versions in
  `deps/` so they describe the code the app ships. Run it after changing
  mob, a plugin or `mob.exs`, and commit the output:

      mix operator.docs
      mix operator.docs --mob-src ~/code/mob --mishka-src ~/code/mob_mishka

  What it writes (one `<name>.md` each, plus `index.md`, the names and one
  line each that the system prompt lists):

    * mob's guides for app code (components, styling, navigation, events,
      ...). The Hex package carries no guides, so they come from the same
      version's HexDocs (`~/.hex/docs/hexpm/mob/<version>/`, fetched with
      `mix hex.docs fetch` when missing; `--hexdocs` names another root).
    * `mob_rules`: the parts of mob's AGENTS.md about app code, from the
      mob checkout (`--mob-src`, default `../mob`) at the dep's version
      (git ref `v<version>`, `<version>` or `release-<version>`; the
      working tree, with a warning, if there is none).
    * `mishka`: mob_mishka's overview (its AGENTS.md, `--mishka-src`,
      default `../mob_mishka`, and README) and every composite tag with
      the first sentence of its moduledoc.
    * Each activated capability plugin's README (`config :mob, :plugins`
      and `:styles` in `mob.exs`), except mob_deliver (the Core's own
      updates, which Dyn code may not call) and mob_mishka (above). The
      line in the index is the package's description.

  Anything the sources no longer have (a guide, an AGENTS.md section) stops
  the task rather than writing a partial set.
  """
  use Mix.Task

  alias Operator.Core.Docs

  @guides [
    {"components", "every ~MOB tag and its props: layout, lists, text, inputs, overlays"},
    {"styling", "props per widget: layout, text, colours, inputs, images, scroll, tab bar"},
    {"theming", "theme tokens, named themes, overriding tokens, switching at runtime"},
    {"navigation", "push/pop/reset, tabs and stacks, transitions, data back on pop"},
    {"events", "tap/change/gesture/scroll events: payloads, throttling, patterns"},
    {"event_model", "how events are addressed and routed; stateful components"},
    {"screen_lifecycle", "mount/render/handle_info, the socket, safe area, crashes, back"},
    {"permissions", "the permission each capability needs; asking again after a denial"},
    {"device_capabilities",
     "haptics, clipboard, share, camera, photos, audio, location, motion, alerts, ..."},
    {"packages", "capability plugins, style packages, component kits"},
    {"data", "Mob.State (small persistent key-value store) and Ecto"},
    {"testing", "testing screens: Mob.ScreenCase, handle_info, Mob.Test"},
    {"background_execution", "what can run while the app is in the background"},
    {"push_notifications", "local and push notifications, silent pushes"}
  ]

  # Sections of mob's AGENTS.md that hold for app code; the rest is about
  # developing mob itself (worktrees, releases, native code, CI).
  @mob_rules [
    {:section, "What Mob is, in one paragraph"},
    {:item, "Pre-empt-failure rules — read before you touch anything",
     "**Default arguments evaluate eagerly.**"},
    {:item, "Pre-empt-failure rules — read before you touch anything",
     "**Compile-time `~r//` literals are unsafe on OTP 28.**"},
    {:item, "Conventions worth knowing", "- **Write UI the LiveView way.**"},
    {:section, "Don't write this slop"}
  ]

  @not_capabilities [:mob_deliver, :mob_mishka]

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [out: :string, hexdocs: :string, mob_src: :string, mishka_src: :string]
      )

    Mix.Task.run("compile")
    written = build(opts)
    Mix.shell().info("Wrote #{length(written)} files to #{opts[:out] || "priv/docs"}")
  end

  @doc """
  Writes the docs and returns their paths. Options: `:out` (default
  `priv/docs`), `:deps` (the deps dir), `:mob_exs`, `:hexdocs` (a root of
  `<package>/<version>/` dirs), `:mob_src`, `:mishka_src`, `:seed` (the Dyn
  seed, whose gallery screens the Mishka guide points to; default
  `priv/dyn_seed`).
  """
  @spec build(keyword()) :: [Path.t()]
  def build(opts \\ []) do
    out = opts[:out] || "priv/docs"
    deps = opts[:deps] || Mix.Project.deps_path()
    mob = version!(deps, :mob)
    mishka = version!(deps, :mob_mishka)
    {plugins, styles} = activated(opts[:mob_exs] || "mob.exs")
    capabilities = (plugins -- @not_capabilities) ++ styles

    guides =
      Enum.map(@guides, fn {name, line} ->
        {name, line, hexdoc!(opts[:hexdocs], "mob", mob, name)}
      end) ++
        [
          {"mob_rules", "mob's rules for app code: pitfalls, idioms, what not to write",
           mob_rules!(opts[:mob_src] || "../mob", mob)},
          {"mishka", "the Mishka widgets: every <Mishka…> tag and what it is",
           mishka!(
             deps,
             opts[:mishka_src] || "../mob_mishka",
             mishka,
             opts[:seed] || "priv/dyn_seed"
           )}
        ] ++
        Enum.map(capabilities, fn app ->
          {Atom.to_string(app), description!(deps, app), readme!(deps, app)}
        end)

    File.mkdir_p!(out)
    Enum.each(Path.wildcard(Path.join(out, "*.md")), &File.rm!/1)

    sources =
      Enum.map_join([{:mob, mob}, {:mob_mishka, mishka}] ++ versions(deps, capabilities), ", ", fn
        {app, v} -> "#{app} #{v}"
      end)

    index =
      "<!-- Generated by `mix operator.docs` from #{sources}. Don't edit. -->\n" <>
        Enum.map_join(guides, "", fn {name, line, _} -> "#{name}: #{line}\n" end)

    paths =
      for {name, _line, text} <- guides do
        path = Path.join(out, name <> ".md")
        File.write!(path, String.trim_trailing(text) <> "\n")
        path
      end

    index_path = Path.join(out, "index.md")
    File.write!(index_path, index)
    [index_path | paths]
  end

  defp activated(mob_exs) do
    mob = Config.Reader.read!(mob_exs)[:mob] || []
    {Keyword.get(mob, :plugins, []), Keyword.get(mob, :styles, [])}
  end

  defp versions(deps, apps), do: Enum.map(apps, &{&1, version!(deps, &1)})

  defp metadata!(deps, app) do
    case :file.consult(Path.join([deps, to_string(app), "hex_metadata.config"])) do
      {:ok, terms} -> terms
      {:error, reason} -> Mix.raise("No Hex metadata for #{app} in #{deps}: #{inspect(reason)}")
    end
  end

  defp version!(deps, app), do: :proplists.get_value("version", metadata!(deps, app))

  # The package description's gist: its first sentence up to any dash,
  # without parentheses and what every plugin says.
  defp description!(deps, app) do
    deps
    |> metadata!(app)
    |> then(&:proplists.get_value("description", &1))
    |> sentence()
    |> String.replace(~r/\s*\([^)]*\)/, "")
    |> String.replace(" for Mob apps", "")
    |> String.split(" — ")
    |> hd()
    |> String.trim_trailing(".")
  end

  defp readme!(deps, app), do: File.read!(Path.join([deps, to_string(app), "README.md"]))

  defp hexdoc!(root, package, version, name) do
    dir = Path.join([root || default_hexdocs(), package, version])
    path = Path.join(dir, name <> ".md")

    unless File.exists?(path) or root do
      Mix.Task.rerun("hex.docs", ["fetch", package, version])
    end

    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> Mix.raise("No #{name}.md in #{package} #{version}'s HexDocs (#{dir})")
    end
  end

  defp default_hexdocs do
    Path.join([System.get_env("HEX_HOME") || Path.expand("~/.hex"), "docs", "hexpm"])
  end

  # The checkout's file at the dep's version when it has a ref for it.
  defp at_version!(src, file, version) do
    refs = ["v#{version}", version, "release-#{version}"]

    found =
      Enum.find_value(refs, fn ref ->
        case System.cmd("git", ["-C", src, "show", "#{ref}:#{file}"], stderr_to_stdout: true) do
          {text, 0} -> text
          _ -> nil
        end
      end)

    found ||
      case File.read(Path.join(src, file)) do
        {:ok, text} ->
          Mix.shell().info("#{src} has no ref for #{version}; using its working tree's #{file}")
          text

        {:error, _} ->
          Mix.raise("No #{file} in #{src} (pass --mob-src / --mishka-src)")
      end
  end

  defp mob_rules!(src, version) do
    agents = at_version!(src, "AGENTS.md", version)

    # Blockquotes there are notes to mob's maintainers.
    rules =
      @mob_rules
      |> Enum.map_join("\n\n", fn
        {:section, title} -> section!(agents, title, "mob's AGENTS.md")
        {:item, title, start} -> agents |> section!(title, "mob's AGENTS.md") |> item!(start)
      end)
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, ">"))
      |> Enum.join("\n")

    """
    # Mob's rules for app code

    From mob #{version}'s AGENTS.md (written for agents working on mob itself): the \
    parts that hold for app code. Rules about mob's own repo, native code and releases \
    are left out.

    #{rules}
    """
  end

  defp mishka!(deps, src, version, seed) do
    agents = at_version!(src, "AGENTS.md", version)
    readme = readme!(deps, :mob_mishka)

    what =
      agents
      |> section!("What mob_mishka is, in one paragraph", "mob_mishka's AGENTS.md")
      |> body()
      |> sentence()

    tags =
      Enum.map_join(MobMishka.composites(), "\n", fn {tag, module} ->
        "- `<#{Macro.camelize(Atom.to_string(tag))}>` (`#{inspect(module)}`): " <>
          first_sentence(module) <> gallery(seed, tag)
      end)

    """
    # Mishka widgets (mob_mishka #{version})

    #{what}

    Each widget's props, events and examples: `read_doc` its module. Where the front's \
    default gallery shows one, its screen is named below: a worked example (`dyn_read` it).

    #{readme |> section!("What's in it", "mob_mishka's README") |> before_code()}

    ## Every composite

    #{tags}
    """
  end

  # The seed's gallery screen for a composite, if it has one.
  defp gallery(seed, tag) do
    file = "showcase/components/#{String.replace_prefix(Atom.to_string(tag), "mishka_", "")}.ex"
    if File.exists?(Path.join(seed, file)), do: " Gallery: `#{file}`.", else: ""
  end

  # A README section up to its first code example and the line introducing
  # it: the README's example shows one event shape for every widget, which
  # isn't so (each widget's moduledoc has its own).
  defp before_code(section) do
    section
    |> String.split("\n")
    |> Enum.take_while(&(not String.starts_with?(&1, "```")))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> String.split("\n\n")
    |> then(fn paras ->
      if String.ends_with?(List.last(paras), ":"), do: Enum.drop(paras, -1), else: paras
    end)
    |> Enum.join("\n\n")
  end

  # Each composite's moduledoc opens with "Native Mob port of Mishka
  # Chelekom's **headless X** — what it is."; keep what it is.
  defp first_sentence(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} ->
        doc |> sentence() |> String.replace(~r/^Native Mob port of .*?\*\* — /, "")

      _ ->
        "(no moduledoc)"
    end
  end

  defp sentence(text) do
    text
    |> String.trim()
    |> String.split("\n\n", parts: 2)
    |> hd()
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s/, parts: 2)
    |> hd()
  end

  # A markdown section by its exact heading (`Operator.Core.Docs.section/2`).
  defp section!(text, title, where) do
    case Docs.section(text, &(&1 == title)) do
      {:ok, section} -> String.trim_trailing(section)
      :error -> Mix.raise("#{where} has no section #{inspect(title)}")
    end
  end

  defp body(section), do: section |> String.split("\n", parts: 2) |> List.last() |> String.trim()

  # One numbered or bulleted item of a section, from the line starting with
  # `start` (after its number) to the next item at the same indentation.
  defp item!(section, start) do
    lines = String.split(section, "\n")

    case Enum.find_index(lines, &(&1 |> strip_number() |> String.starts_with?(start))) do
      nil ->
        Mix.raise("mob's AGENTS.md has no item starting #{inspect(start)}")

      i ->
        # Continuation lines are indented under the item; dedented here.
        rest =
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(&(&1 == "" or String.starts_with?(&1, " ")))
          |> Enum.map(&String.trim_leading/1)

        Enum.join([strip_number(Enum.at(lines, i)) | rest], "\n") |> String.trim_trailing()
    end
  end

  defp strip_number(line), do: String.replace(line, ~r/^\d+\.\s+/, "")
end
