defmodule Operator.Core.SelfKnowledgeTest do
  use ExUnit.Case, async: true

  alias Operator.Core.SelfKnowledge
  alias Operator.Core.Tools.{Instructions, Skill}

  @moduletag :tmp_dir

  defp ctx(dir), do: %{data_dir: dir, session_id: "s", call_id: "c"}
  defp instr(args, dir), do: Instructions.run(args, ctx(dir))
  defp skill(args, dir), do: Skill.run(args, ctx(dir))

  test "the tools pass their own selftests" do
    assert Instructions.selftest() == :ok
    assert Skill.selftest() == :ok
  end

  describe "instructions" do
    test "replace edits one exact match and refuses a missing or repeated one", %{tmp_dir: dir} do
      {:ok, _} = instr(%{"action" => "write", "content" => "use dp\nuse dp\nno sleep\n"}, dir)

      assert {:error, "old_text matches 2 times" <> _} =
               instr(%{"action" => "replace", "old_text" => "use dp", "new_text" => "x"}, dir)

      assert {:error, "old_text was not found" <> _} =
               instr(%{"action" => "replace", "old_text" => "Use dp", "new_text" => "x"}, dir)

      assert {:ok, _} =
               instr(%{"action" => "replace", "old_text" => "no sleep", "new_text" => ""}, dir)

      assert {:ok, "use dp\nuse dp\n\n"} = instr(%{"action" => "read"}, dir)
    end

    test "append adds a paragraph; an over-limit file is refused unchanged", %{tmp_dir: dir} do
      assert {:ok, "(no instructions yet)"} = instr(%{"action" => "read"}, dir)
      {:ok, _} = instr(%{"action" => "append", "text" => "one\n"}, dir)
      {:ok, _} = instr(%{"action" => "append", "text" => "two"}, dir)
      assert {:ok, "one\n\ntwo\n"} = instr(%{"action" => "read"}, dir)

      big = String.duplicate("x", 40_000)

      assert {:error, "AGENTS.md would be" <> _} =
               instr(%{"action" => "append", "text" => big}, dir)

      assert {:ok, "one\n\ntwo\n"} = instr(%{"action" => "read"}, dir)
    end

    test "the prompt shows the file under its heading, or nothing", %{tmp_dir: dir} do
      assert SelfKnowledge.prompt_section(dir) == ""
      {:ok, _} = instr(%{"action" => "write", "content" => "  \n"}, dir)
      assert SelfKnowledge.prompt_section(dir) == ""

      {:ok, _} = instr(%{"action" => "write", "content" => "Always use dp.\n"}, dir)

      assert SelfKnowledge.prompt_section(dir) ==
               "## Your own instructions (AGENTS.md, written by you)\n\nAlways use dp."
    end

    test "past the cap the prompt shows whole lines up to it and says how to read the rest",
         %{tmp_dir: dir} do
      cap = SelfKnowledge.instructions_cap()
      line = String.duplicate("é", 49) <> "\n"
      body = String.duplicate(line, div(2 * cap, byte_size(line)))
      {:ok, saved} = instr(%{"action" => "write", "content" => body}, dir)
      assert saved =~ "Only the first #{cap} bytes reach your prompt"

      section = SelfKnowledge.prompt_section(dir)
      assert String.valid?(section)
      [shown, note] = String.split(section, "\n\n(AGENTS.md is ")

      shown =
        String.replace_prefix(
          shown,
          "## Your own instructions (AGENTS.md, written by you)\n\n",
          ""
        )

      assert byte_size(shown) <= cap
      assert byte_size(shown) > cap - byte_size(line)
      assert String.ends_with?(shown, "é")
      assert note =~ "#{byte_size(String.trim(body))} bytes"
      assert note =~ "`instructions` action=read"
    end
  end

  describe "skills" do
    test "names must be lowercase letters, digits and dashes", %{tmp_dir: dir} do
      write = %{"action" => "write", "description" => "d", "content" => "x"}

      for bad <- ["../evil", "a/b", "Caps", "-lead", "a.b", "", String.duplicate("a", 49)] do
        assert {:error, "invalid skill name" <> _} = skill(Map.put(write, "name", bad), dir)
      end

      assert {:error, "invalid skill name" <> _} =
               skill(%{"action" => "read", "name" => ".."}, dir)

      assert {:ok, _} = skill(Map.put(write, "name", "widget-build-2"), dir)
      assert File.ls!(Path.join(dir, "skills")) == ["widget-build-2.md"]
    end

    test "a skill needs a description, given or in its own header", %{tmp_dir: dir} do
      assert {:error, "write needs a `description`" <> _} =
               skill(%{"action" => "write", "name" => "a", "content" => "steps"}, dir)

      assert {:ok, _} =
               skill(
                 %{"action" => "write", "name" => "a", "content" => "description: own\nsteps"},
                 dir
               )

      # A given description replaces the header the content had.
      assert {:ok, "Replaced skill a" <> _} =
               skill(
                 %{
                   "action" => "write",
                   "name" => "a",
                   "description" => "new",
                   "content" => "---\nname: a\ndescription: old\n---\nsteps"
                 },
                 dir
               )

      assert {:ok, "---\nname: a\ndescription: new\n---\n\nsteps\n"} =
               skill(%{"action" => "read", "name" => "a"}, dir)
    end

    test "the prompt lists each skill with its description and the rule to read it",
         %{tmp_dir: dir} do
      for {name, d} <- [{"zeta", "last one"}, {"alpha", "first one"}] do
        {:ok, _} =
          skill(%{"action" => "write", "name" => name, "description" => d, "content" => "s"}, dir)
      end

      # Hand-written files: frontmatter without a description, and an invalid name.
      File.write!(Path.join([dir, "skills", "bare.md"]), "just steps")
      File.write!(Path.join([dir, "skills", "Bad Name.md"]), "description: hidden")

      section = SelfKnowledge.prompt_section(dir)
      assert section =~ "## Your skills"
      assert section =~ "`skill` action=read"
      assert section =~ "- alpha: first one\n- bare: (no description)\n- zeta: last one"
      refute section =~ "hidden"
      refute section =~ "AGENTS.md"

      {:ok, _} = skill(%{"action" => "delete", "name" => "zeta"}, dir)
      refute SelfKnowledge.prompt_section(dir) =~ "zeta"
      assert {:error, "no skill zeta"} = skill(%{"action" => "delete", "name" => "zeta"}, dir)
    end

    test "the prompt lists at most 40 skills and clips long descriptions", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "skills"))

      for n <- 1..45 do
        name = "s#{String.pad_leading("#{n}", 2, "0")}"

        File.write!(
          Path.join([dir, "skills", name <> ".md"]),
          "description: #{String.duplicate("d", 500)}\n"
        )
      end

      lines =
        SelfKnowledge.prompt_section(dir) |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^- /))

      assert Enum.count(lines) == 41
      assert List.last(lines) =~ "5 more"
      assert Enum.all?(Enum.take(lines, 40), &(String.length(&1) < 220))
    end

    test "both sections together, instructions first", %{tmp_dir: dir} do
      {:ok, _} = instr(%{"action" => "write", "content" => "rule"}, dir)

      {:ok, _} =
        skill(%{"action" => "write", "name" => "a", "description" => "d", "content" => "s"}, dir)

      assert SelfKnowledge.prompt_section(dir) =~
               ~r/\A## Your own instructions.*rule\n\n## Your skills/s
    end
  end
end
