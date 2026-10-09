defmodule Operator.Core.Tools.Skill do
  @moduledoc """
  Core tool: the agent's skills, `skills/<name>.md` in the app's data dir.
  A skill is a procedure the agent worked out (how to build and test a
  widget for a plugin, how to get around a known trap) written so its
  future self can follow it. Only each skill's name and description are in
  the system prompt (`Operator.Core.SelfKnowledge`); the agent reads the
  whole skill when a task matches, so many skills cost little prompt.

  A file starts with a `---` frontmatter block holding `name:` and
  `description:` (omp's SKILL.md shape); a first line `description: ...`
  is read too. Names are lowercase letters, digits and dashes, so a name
  can never reach outside the skills dir.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.SelfKnowledge

  @max_bytes 32 * 1024
  @max_skills 100
  @max_description 300

  @impl true
  def name, do: "skill"

  @impl true
  def description do
    "Your skills: procedures you worked out (how to build and test a kind of screen or " <>
      "tool, how to get around a known trap), written so your future self can follow " <>
      "them. Your prompt lists each one's name and description; when a task matches one, " <>
      "read it first. action=list; read `name`; write `name` with `description` (one line: " <>
      "when to use it) and `content` (the steps, Markdown), replacing any skill of that " <>
      "name; delete `name`. Names: lowercase letters, digits, dashes."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["list", "read", "write", "delete"]},
        "name" => %{"type" => "string", "description" => "e.g. plugin-widget-build"},
        "description" => %{
          "type" => "string",
          "description" => "One line: what it does and when to use it (action=write)."
        },
        "content" => %{"type" => "string", "description" => "The procedure (action=write)."}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"action" => "list"}, ctx) do
    case SelfKnowledge.skills(ctx.data_dir) do
      [] ->
        {:ok, "(no skills yet)"}

      skills ->
        {:ok, Enum.map_join(skills, "\n", &"#{&1.name}: #{&1.description || "(no description)"}")}
    end
  end

  def run(%{"action" => "read", "name" => name}, ctx) do
    with {:ok, path} <- SelfKnowledge.skill_path(ctx.data_dir, name) do
      case File.read(path) do
        {:ok, body} -> {:ok, body}
        {:error, :enoent} -> {:error, "no skill #{name}; `skill` action=list shows them"}
        {:error, reason} -> {:error, "could not read #{name}: #{:file.format_error(reason)}"}
      end
    end
  end

  def run(%{"action" => "write", "name" => name, "content" => content} = args, ctx)
      when is_binary(content) do
    with {:ok, path} <- SelfKnowledge.skill_path(ctx.data_dir, name),
         {:ok, body} <- body(name, args["description"], content),
         :ok <- room(ctx.data_dir, path) do
      existed = File.exists?(path)

      with :ok <- SelfKnowledge.write_atomic(path, body) do
        {:ok,
         "#{if existed, do: "Replaced", else: "Wrote"} skill #{name} (#{byte_size(body)} bytes)."}
      end
    end
  end

  def run(%{"action" => "delete", "name" => name}, ctx) do
    with {:ok, path} <- SelfKnowledge.skill_path(ctx.data_dir, name) do
      case File.rm(path) do
        :ok -> {:ok, "Deleted skill #{name}."}
        {:error, :enoent} -> {:error, "no skill #{name}"}
        {:error, reason} -> {:error, "could not delete #{name}: #{:file.format_error(reason)}"}
      end
    end
  end

  def run(%{"action" => action}, _ctx) when action in ["read", "delete"],
    do: {:error, "#{action} needs `name`"}

  def run(%{"action" => "write"}, _ctx),
    do: {:error, "write needs `name`, `description` and `content`"}

  def run(args, _ctx),
    do: {:error, "unknown action: #{inspect(args["action"])}; use list, read, write or delete"}

  # A given description replaces whatever header `content` had; without
  # one, `content` must carry its own.
  defp body(name, description, content) when is_binary(description) do
    case String.trim(description) |> String.replace(~r/\s+/, " ") do
      "" -> body(name, nil, content)
      d -> check(frontmatter(name, d) <> strip_header(content))
    end
  end

  defp body(_name, nil, content) do
    if SelfKnowledge.description(content),
      do: check(content),
      else:
        {:error,
         "write needs a `description`: one line saying what the skill does and when to use it"}
  end

  defp check(body) do
    d = SelfKnowledge.description(body)

    cond do
      String.length(d) > @max_description ->
        {:error,
         "the description is #{String.length(d)} characters; keep it under #{@max_description}"}

      byte_size(body) > @max_bytes ->
        {:error, "the skill is #{byte_size(body)} bytes; the limit is #{@max_bytes}. Split it."}

      true ->
        {:ok, body}
    end
  end

  defp frontmatter(name, description),
    do: "---\nname: #{name}\ndescription: #{description}\n---\n\n"

  defp strip_header(content) do
    trimmed = String.trim_leading(content)

    rest =
      case String.split(trimmed, "\n") do
        ["---" <> _ | lines] ->
          case Enum.split_while(lines, &(String.trim(&1) != "---")) do
            {_header, [_close | body]} -> Enum.join(body, "\n")
            {_unclosed, []} -> trimmed
          end

        ["description:" <> _ | body] ->
          Enum.join(body, "\n")

        _ ->
          trimmed
      end

    String.trim(rest) <> "\n"
  end

  defp room(data_dir, path) do
    if File.exists?(path) or length(SelfKnowledge.skills(data_dir)) < @max_skills,
      do: :ok,
      else: {:error, "you have #{@max_skills} skills, the limit; delete or merge some first"}
  end

  @impl true
  def selftest do
    dir = Path.join(System.tmp_dir!(), "operator-skill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ctx = %{data_dir: dir}
    write = %{"action" => "write", "name" => "a-b", "description" => "d", "content" => "x"}

    try do
      with {:ok, "(no skills yet)"} <- run(%{"action" => "list"}, ctx),
           {:error, "invalid skill name" <> _} <- run(%{write | "name" => "../a"}, ctx),
           {:ok, "Wrote skill a-b" <> _} <- run(write, ctx),
           {:ok, "a-b: d"} <- run(%{"action" => "list"}, ctx),
           {:ok, "---\nname: a-b\ndescription: d\n---\n\nx\n"} <-
             run(%{"action" => "read", "name" => "a-b"}, ctx),
           {:ok, _} <- run(%{"action" => "delete", "name" => "a-b"}, ctx),
           {:ok, "(no skills yet)"} <- run(%{"action" => "list"}, ctx) do
        :ok
      else
        other -> {:error, other}
      end
    after
      File.rm_rf!(dir)
    end
  end
end
