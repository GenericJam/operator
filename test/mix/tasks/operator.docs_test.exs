defmodule Mix.Tasks.Operator.DocsTest do
  # async: false: Mix.shell/1 is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Operator.Docs, as: DocsTask

  @moduletag :tmp_dir

  @guides ~w(components styling theming navigation events event_model screen_lifecycle
             permissions device_capabilities packages data testing background_execution
             push_notifications)

  setup %{tmp_dir: tmp} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    deps = Path.join(tmp, "deps")

    for {app, version, description} <- [
          {"mob", "9.9.1", "Mob"},
          {"mob_mishka", "9.9.2", "Mishka composites for Mob apps"},
          {"mob_camera", "9.9.3", "Native camera capture for Mob apps (extracted from mob core)"},
          {"mob_deliver", "9.9.4", "OTA updates"},
          {"mob_themes", "9.9.5", "Themes — five looks in one package"},
          {"mob_rapier", "9.9.6", "Rapier 3D physics for Mob apps"}
        ] do
      dir = Path.join(deps, app)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "hex_metadata.config"),
        ~s({<<"name">>,<<"#{app}">>}.\n{<<"version">>,<<"#{version}">>}.\n) <>
          ~s({<<"description">>,<<"#{description}"/utf8>>}.\n)
      )

      File.write!(Path.join(dir, "README.md"), "# #{app} readme\n")
    end

    File.write!(
      Path.join([deps, "mob_mishka", "README.md"]),
      "# mob_mishka\n\nInstall it.\n\n## What's in it\n\nSeventy-three widgets.\n\n" <>
        "Use them like this:\n\n```elixir\ndef handle_info({:tap, :x, v}, s)\n```\n\n" <>
        "More after the example.\n\n## Migrating\n\nMac only.\n"
    )

    hexdocs = Path.join([tmp, "hexdocs", "mob", "9.9.1"])
    File.mkdir_p!(hexdocs)

    for g <- @guides ++ ["publishing"],
        do: File.write!(Path.join(hexdocs, g <> ".md"), "# #{g}\n")

    mob_src = Path.join(tmp, "mob")
    File.mkdir_p!(mob_src)
    File.write!(Path.join(mob_src, "AGENTS.md"), mob_agents())

    mishka_src = Path.join(tmp, "mob_mishka")
    File.mkdir_p!(mishka_src)

    File.write!(
      Path.join(mishka_src, "AGENTS.md"),
      "# AGENTS\n\n## What mob_mishka is, in one paragraph\n\nShips 73 composites. Eject them.\n\n" <>
        "Epic links.\n\n## Release flow\n\nTag it.\n"
    )

    mob_exs = Path.join(tmp, "mob.exs")

    File.write!(mob_exs, """
    import Config
    config :mob, :plugins, [:mob_camera, :mob_deliver, :mob_mishka]
    config :mob, :styles, [:mob_themes]
    """)

    out = Path.join(tmp, "out")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "stale.md"), "from an older run")

    seed = Path.join(tmp, "seed")
    File.mkdir_p!(Path.join(seed, "showcase/components"))
    File.write!(Path.join(seed, "showcase/components/tabs.ex"), "")

    opts = [
      out: out,
      deps: deps,
      mob_exs: mob_exs,
      hexdocs: Path.join(tmp, "hexdocs"),
      mob_src: mob_src,
      mishka_src: mishka_src,
      seed: seed
    ]

    %{opts: opts, out: out, hexdocs: hexdocs}
  end

  defp mob_agents do
    """
    # Mob — Agent Instructions

    ## What Mob is, in one paragraph

    Elixir on the phone.

    ## Worktrees

    Use worktrees.

    ## Pre-empt-failure rules — read before you touch anything

    1. **Default arguments evaluate eagerly.** `Path.expand("~")`
       raises on Android.

    2. **Never call the render NIFs outside `Mob.Sender`.** Native detail.

    10. **Compile-time `~r//` literals are unsafe on OTP 28.** Use
        `Regex.compile!/2`.

    11. **Something else.** Not shipped.

    ## Conventions worth knowing

    - **Terse responses.** Be short.
    - **Write UI the LiveView way.** Use `:if` and `:for`
      attributes.

    ## Don't write this slop

    **Maps**
    - Pick one key type per map.

    > **Periodic check:** update the linter.

    ## Release flow

    Bump the version.
    """
  end

  defp read(out, name), do: File.read!(Path.join(out, name <> ".md"))

  test "writes mob's guides, the rules, Mishka and the activated plugins, from deps", %{
    opts: opts,
    out: out
  } do
    DocsTask.build(opts)

    names =
      out |> Path.join("*.md") |> Path.wildcard() |> Enum.map(&Path.basename(&1, ".md"))

    assert Enum.sort(names) ==
             Enum.sort(@guides ++ ~w(mob_rules mishka mob_camera mob_rapier mob_themes index))

    # Guides are the dep's version's HexDocs, as they are.
    assert read(out, "components") == "# components\n"

    # The plugins' READMEs; the index gives each the gist of its description.
    assert read(out, "mob_camera") == "# mob_camera readme\n"
    index = read(out, "index")
    assert index =~ "\nmob_camera: Native camera capture\n"
    assert index =~ "\nmob_themes: Themes\n"
    assert index =~ "\nmob_rapier: Rapier 3D physics\n"
    assert index =~ "mob 9.9.1, mob_mishka 9.9.2"
    assert index =~ "\ncomponents: "

    rules = read(out, "mob_rules")
    assert rules =~ "## What Mob is, in one paragraph\n\nElixir on the phone."

    assert rules =~
             "**Default arguments evaluate eagerly.** `Path.expand(\"~\")`\nraises on Android."

    assert rules =~
             "**Compile-time `~r//` literals are unsafe on OTP 28.** Use\n`Regex.compile!/2`."

    assert rules =~ "- **Write UI the LiveView way.** Use `:if` and `:for`\nattributes."
    assert rules =~ "- Pick one key type per map."

    for left_out <- ["Worktrees", "render NIFs", "Something else", "Terse", "Periodic", "Bump"],
        do: refute(rules =~ left_out)

    mishka = read(out, "mishka")
    assert mishka =~ "mob_mishka 9.9.2"
    assert mishka =~ "Ships 73 composites."
    refute mishka =~ "Epic links"
    assert mishka =~ "## What's in it\n\nSeventy-three widgets."
    refute mishka =~ "Mac only"
    # The README's example (one event shape for every widget) and its intro are left out.
    refute mishka =~ "Use them like this"
    refute mishka =~ "handle_info({:tap, :x"
    # Every composite the shipped mob_mishka registers, by tag, with the
    # seed's gallery screen when it has one.
    assert mishka =~
             ~r/- `<MishkaTabs>` \(`MobMishka.Components.MishkaTabs`\): [^\n]* Gallery: `showcase\/components\/tabs.ex`.\n/

    refute mishka =~ ~r/`<MishkaAccordion>`[^\n]*Gallery/

    for {tag, _} <- MobMishka.composites(),
        do: assert(mishka =~ "`<#{Macro.camelize(Atom.to_string(tag))}>`")
  end

  test "a guide the dep's HexDocs lacks stops the run", %{opts: opts, hexdocs: hexdocs, out: out} do
    File.rm!(Path.join(hexdocs, "navigation.md"))
    assert_raise Mix.Error, ~r/navigation\.md/, fn -> DocsTask.build(opts) end
    assert File.exists?(Path.join(out, "stale.md"))
  end

  test "an AGENTS.md section that's gone stops the run", %{opts: opts} do
    agents = Path.join(opts[:mob_src], "AGENTS.md")

    File.write!(
      agents,
      String.replace(File.read!(agents), "## Don't write this slop", "## Other")
    )

    assert_raise Mix.Error, ~r/Don't write this slop/, fn -> DocsTask.build(opts) end
  end
end
