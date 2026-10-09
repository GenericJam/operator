defmodule Operator.Core.Tools.Instructions do
  @moduledoc """
  Core tool: the agent's own standing instructions, `AGENTS.md` in the app's
  data dir. `Operator.Core.SelfKnowledge` puts the file into the system
  prompt on every model call, so what the agent writes here (a lesson, a
  convention, the fix for a trap it keeps hitting) is known from the start
  of every later session. It is how the agent changes its own behaviour
  without a Core update. Edits are exact-match replacements, like
  `dyn_edit`, so the file is kept current rather than appended to forever.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.SelfKnowledge

  # The file may grow past what the prompt shows (SelfKnowledge cuts it),
  # but not without bound.
  @max_bytes 32 * 1024

  @impl true
  def name, do: "instructions"

  @impl true
  def description do
    "Your own instructions (AGENTS.md), shown in your system prompt at the start of every " <>
      "session and every turn. Put here what your future self must know: durable lessons, " <>
      "conventions the user wants, the fix for a recurring problem. Keep it short and " <>
      "current: prefer replace over append, and don't add a duplicate of what's there. " <>
      "action=read; append `text` as a new paragraph; replace `old_text` (must occur exactly " <>
      "once, whitespace included) with `new_text` (\"\" deletes it); write the whole file " <>
      "as `content`."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["read", "append", "replace", "write"]},
        "text" => %{"type" => "string", "description" => "Markdown to append (action=append)."},
        "old_text" => %{"type" => "string", "description" => "Exact text to replace."},
        "new_text" => %{"type" => "string", "description" => "Its replacement."},
        "content" => %{"type" => "string", "description" => "The whole file (action=write)."}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"action" => "read"}, ctx) do
    case read(ctx) do
      {:ok, ""} -> {:ok, "(no instructions yet)"}
      {:ok, body} -> {:ok, body}
      error -> error
    end
  end

  def run(%{"action" => "append", "text" => text}, ctx) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:error, "append needs a non-empty `text`"}

      text ->
        update(ctx, fn
          "" -> {:ok, text <> "\n"}
          body -> {:ok, String.trim_trailing(body) <> "\n\n" <> text <> "\n"}
        end)
    end
  end

  def run(%{"action" => "append"}, _ctx), do: {:error, "append needs a non-empty `text`"}

  def run(%{"action" => "replace", "old_text" => old, "new_text" => new}, ctx)
      when is_binary(old) and old != "" and is_binary(new) do
    update(ctx, fn body ->
      case :binary.matches(body, old) do
        [_one] ->
          {:ok, String.replace(body, old, new)}

        [] ->
          {:error,
           "old_text was not found in AGENTS.md (0 matches). Read it and copy the text " <>
             "exactly, whitespace included."}

        matches ->
          {:error,
           "old_text matches #{length(matches)} times in AGENTS.md. Include more " <>
             "surrounding text so it matches exactly once."}
      end
    end)
  end

  def run(%{"action" => "replace"}, _ctx),
    do: {:error, "replace needs a non-empty `old_text` and `new_text`"}

  def run(%{"action" => "write", "content" => content}, ctx) when is_binary(content),
    do: update(ctx, fn _ -> {:ok, content} end)

  def run(%{"action" => "write"}, _ctx), do: {:error, "write needs `content`"}

  def run(args, _ctx),
    do: {:error, "unknown action: #{inspect(args["action"])}; use read, append, replace or write"}

  defp update(ctx, fun) do
    path = SelfKnowledge.instructions_path(ctx.data_dir)

    SelfKnowledge.with_lock(path, fn ->
      with {:ok, body} <- read(ctx),
           {:ok, new} <- fun.(body),
           :ok <- fits(new),
           :ok <- SelfKnowledge.write_atomic(path, new) do
        {:ok, saved(new)}
      end
    end)
  end

  defp fits(body) when byte_size(body) <= @max_bytes, do: :ok

  defp fits(body) do
    {:error,
     "AGENTS.md would be #{byte_size(body)} bytes; the limit is #{@max_bytes}. Shorten it: " <>
       "merge or drop what is stale, move long procedures into a `skill`."}
  end

  defp saved(body) do
    cap = SelfKnowledge.instructions_cap()
    size = byte_size(String.trim(body))

    if size > cap,
      do:
        "Saved (#{size} bytes). Only the first #{cap} bytes reach your prompt: shorten it, " <>
          "or move long procedures into a `skill`.",
      else: "Saved (#{size} bytes). Your prompt shows it from the next model call on."
  end

  defp read(ctx) do
    case File.read(SelfKnowledge.instructions_path(ctx.data_dir)) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, "could not read AGENTS.md: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def selftest do
    dir = Path.join(System.tmp_dir!(), "operator-instr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ctx = %{data_dir: dir}

    try do
      with {:ok, "(no instructions yet)"} <- run(%{"action" => "read"}, ctx),
           {:ok, _} <- run(%{"action" => "append", "text" => "a b"}, ctx),
           {:ok, _} <- run(%{"action" => "append", "text" => "b"}, ctx),
           {:error, "old_text matches 2 times" <> _} <-
             run(%{"action" => "replace", "old_text" => "b", "new_text" => "c"}, ctx),
           {:ok, _} <- run(%{"action" => "replace", "old_text" => "a b", "new_text" => "c"}, ctx),
           {:ok, "c\n\nb\n"} <- run(%{"action" => "read"}, ctx) do
        :ok
      else
        other -> {:error, other}
      end
    after
      File.rm_rf!(dir)
    end
  end
end
