defmodule Operator.Core.Tools.ReadGuide do
  @moduledoc """
  Core tool: read one of the guides bundled with the app
  (`Operator.Core.Docs`): mob's guides, its rules for app code, the Mishka
  widgets, each capability plugin's README. Whole, one section, or a range
  of lines; a guide over the output budget is cut like any long output
  (`Operator.Core.Artifacts`), after a list of its sections.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Artifacts
  alias Operator.Core.Docs

  @impl true
  def name, do: "read_guide"

  @impl true
  def description do
    "Read a guide bundled with the app (mob's guides, Mishka widgets, plugin READMEs; the " <>
      "system prompt lists them). Read the relevant one before writing code with an API you " <>
      "haven't used. section: one section by its heading (case-insensitive, a part of it " <>
      "will do); offset and limit: a range of lines. An unknown name lists the guides."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "The guide, e.g. components."},
        "section" => %{"type" => "string", "description" => "A heading, e.g. Control flow."},
        "offset" => %{"type" => "integer", "minimum" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["name"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"name" => name} = args, _ctx) when is_binary(name) do
    with {:ok, text} <- guide(name),
         {:ok, text} <- section(text, args["section"], name) do
      {:ok, page(text, args["offset"], args["limit"], args["section"])}
    end
  end

  def run(_args, _ctx), do: {:error, "read_guide needs a `name`. " <> list()}

  defp guide(name) do
    key = name |> String.trim() |> Path.basename(".md") |> String.downcase()

    case Docs.guide(key) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "No guide #{inspect(name)}. " <> list()}
    end
  end

  defp list do
    "The guides:\n" <> Enum.map_join(Docs.index(), "\n", fn {n, about} -> "#{n}: #{about}" end)
  end

  defp section(text, nil, _name), do: {:ok, text}

  defp section(text, wanted, name) when is_binary(wanted) do
    want =
      wanted |> String.trim() |> String.trim_leading("#") |> String.trim() |> String.downcase()

    with :error <- Docs.section(text, &(String.downcase(&1) == want)),
         :error <- Docs.section(text, &String.contains?(String.downcase(&1), want)) do
      {:error,
       "No section #{inspect(wanted)} in #{name}. Its sections:\n" <>
         contents(Docs.headings(text))}
    end
  end

  defp section(_text, wanted, _name),
    do: {:error, "section must be a heading, got #{inspect(wanted)}"}

  # The whole text (prefaced with its sections if it's long enough to be
  # cut), or the lines asked for.
  defp page(text, nil, nil, section) do
    if is_nil(section) and byte_size(text) > Artifacts.budget() do
      lines = length(Docs.lines(text))

      "(#{lines} lines, too long to show whole: ask for a `section`, or read the cut part " <>
        "with read_artifact. Its sections:)\n" <>
        contents(Docs.headings(text)) <> "\n\n" <> text
    else
      text
    end
  end

  defp page(text, offset, limit, _section) do
    lines = Docs.lines(text)
    total = length(lines)
    first = positive(offset, 1)
    taken = lines |> Enum.drop(first - 1) |> Enum.take(positive(limit, total))
    last = first + length(taken) - 1

    cond do
      taken == [] ->
        "(#{total} lines; offset #{first} is past the end)"

      last < total ->
        Enum.join(taken, "\n") <>
          "\n[lines #{first}-#{last} of #{total}; continue with offset #{last + 1}]"

      true ->
        Enum.join(taken, "\n") <> "\n[lines #{first}-#{last} of #{total}; end]"
    end
  end

  defp contents(headings) do
    Enum.map_join(headings, "\n", fn {_, level, title} ->
      String.duplicate("  ", max(level - 1, 0)) <> "- " <> title
    end)
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_n, default), do: default

  @impl true
  def selftest do
    case {run(%{"name" => "components", "section" => "control flow"}, %{}),
          run(%{"name" => "nope"}, %{})} do
      {{:ok, "## Control flow" <> _}, {:error, "No guide" <> _}} -> :ok
      other -> {:error, "selftest failed: #{inspect(other, limit: 5)}"}
    end
  end
end
