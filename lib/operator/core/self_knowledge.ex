defmodule Operator.Core.SelfKnowledge do
  @moduledoc """
  What the agent has taught itself, kept in the app's data dir and put back
  into its system prompt on every model call, so the next session starts
  knowing it (omp's AGENTS.md and skills, on the phone):

    * `AGENTS.md`: its own standing instructions (lessons, conventions,
      fixes for recurring problems), edited with the `instructions` tool.
      Injected whole up to `instructions_cap/0` bytes; past that only the
      start, with a line saying how to read the rest.
    * `skills/<name>.md`: procedures it worked out, written with the `skill`
      tool. Only each skill's name and one-line description go into the
      prompt; the agent reads the whole skill when a task matches.

  Both live outside the workspace, so the user's files and the agent's own
  memory don't mix. Everything here is bounded: the prompt is paid for on
  every call, and the phone has little RAM.
  """

  @instructions_file "AGENTS.md"
  @skills_dir "skills"
  @instructions_cap 8 * 1024
  @max_listed_skills 40
  @max_description 200
  @name_re ~r/\A[a-z0-9][a-z0-9-]{0,47}\z/

  @doc "Bytes of `AGENTS.md` injected into the prompt."
  @spec instructions_cap() :: pos_integer()
  def instructions_cap, do: @instructions_cap

  @spec instructions_path(String.t()) :: String.t()
  def instructions_path(data_dir), do: Path.join(data_dir, @instructions_file)

  @spec skills_dir(String.t()) :: String.t()
  def skills_dir(data_dir), do: Path.join(data_dir, @skills_dir)

  @doc """
  The skill's file, or an error the model can act on when `name` isn't a
  valid skill name (lowercase letters, digits and dashes, starting with a
  letter or digit, at most 48 characters; so never a path).
  """
  @spec skill_path(String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def skill_path(data_dir, name) do
    if valid_skill_name?(name),
      do: {:ok, Path.join(skills_dir(data_dir), name <> ".md")},
      else:
        {:error,
         "invalid skill name #{inspect(name)}: use lowercase letters, digits and dashes " <>
           "(e.g. widget-build), at most 48 characters"}
  end

  @spec valid_skill_name?(term()) :: boolean()
  def valid_skill_name?(name), do: is_binary(name) and Regex.match?(@name_re, name)

  @doc """
  Every valid skill as `%{name:, description:}`, sorted by name. A file
  without a description is listed with `description: nil`.
  """
  @spec skills(String.t()) :: [%{name: String.t(), description: String.t() | nil}]
  def skills(data_dir) do
    dir = skills_dir(data_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.filter(&valid_skill_name?/1)
        |> Enum.sort()
        |> Enum.map(&%{name: &1, description: read_description(Path.join(dir, &1 <> ".md"))})

      {:error, _} ->
        []
    end
  end

  @doc """
  The description of a skill file's body: the `description:` of a leading
  `---` frontmatter block, or a first line `description: ...`; nil if none.
  """
  @spec description(String.t()) :: String.t() | nil
  def description(body) do
    lines = body |> String.trim_leading() |> String.split("\n")

    header =
      case lines do
        ["---" <> _ | rest] -> Enum.take_while(rest, &(String.trim(&1) != "---"))
        [first | _] -> [first]
        [] -> []
      end

    Enum.find_value(header, fn line ->
      case Regex.run(~r/\A\s*description:\s*(.*?)\s*\z/, line) do
        [_, d] when d != "" -> d |> String.trim("\"") |> String.trim("'")
        _ -> nil
      end
    end)
  end

  @doc """
  The system-prompt section for `data_dir`: the agent's own instructions
  and its skills, or `""` when it has neither.
  """
  @spec prompt_section(String.t()) :: String.t()
  def prompt_section(data_dir) do
    [instructions_section(data_dir), skills_section(data_dir)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc false
  @spec instructions_section(String.t()) :: String.t()
  def instructions_section(data_dir) do
    case File.read(instructions_path(data_dir)) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> ""
          text -> "## Your own instructions (AGENTS.md, written by you)\n\n" <> capped(text)
        end

      {:error, _} ->
        ""
    end
  end

  defp capped(text) when byte_size(text) <= @instructions_cap, do: text

  defp capped(text) do
    head = binary_part(text, 0, @instructions_cap)
    # Cut at the last whole line, and never inside a UTF-8 character.
    head =
      case :binary.matches(head, "\n") do
        [] -> valid_prefix(head)
        matches -> binary_part(head, 0, matches |> List.last() |> elem(0))
      end

    "#{String.trim_trailing(head)}\n\n(AGENTS.md is #{byte_size(text)} bytes; only the first " <>
      "#{byte_size(head)} are shown here. Read it all with `instructions` action=read, then " <>
      "shorten it.)"
  end

  defp valid_prefix(bin) do
    case :unicode.characters_to_binary(bin) do
      valid when is_binary(valid) -> valid
      {_incomplete_or_error, valid, _rest} -> valid
    end
  end

  @doc """
  Runs `fun` holding a lock on `path` on this node, so the parallel tool
  calls of one turn don't lose each other's read-modify-write.
  """
  @spec with_lock(String.t(), (-> result)) :: result when result: term()
  def with_lock(path, fun), do: :global.trans({{__MODULE__, path}, self()}, fun, [node()])

  @doc "Writes `body` to `path` through a temp file, so a crash never leaves half a file."
  @spec write_atomic(String.t(), iodata()) :: :ok | {:error, String.t()}
  def write_atomic(path, body) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  @spec skills_section(String.t()) :: String.t()
  def skills_section(data_dir) do
    case skills(data_dir) do
      [] ->
        ""

      all ->
        {shown, rest} = Enum.split(all, @max_listed_skills)
        lines = Enum.map(shown, &"- #{&1.name}: #{clip(&1.description)}")
        more = if rest == [], do: [], else: ["- (#{length(rest)} more: `skill` action=list)"]

        Enum.join(
          [
            "## Your skills",
            "",
            "Procedures you worked out and wrote down. When a task matches one, read it " <>
              "first with `skill` action=read and follow it."
            | ["" | lines ++ more]
          ],
          "\n"
        )
    end
  end

  defp clip(nil), do: "(no description)"

  defp clip(d) do
    d = d |> String.replace(~r/\s+/, " ")

    if String.length(d) > @max_description,
      do: String.slice(d, 0, @max_description) <> "…",
      else: d
  end

  # Only the head of the file: a description is on its first lines.
  defp read_description(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 2048)) do
      {:ok, data} when is_binary(data) -> data |> valid_prefix() |> description()
      _ -> nil
    end
  end
end
