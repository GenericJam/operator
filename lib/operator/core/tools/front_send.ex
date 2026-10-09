defmodule Operator.Core.Tools.FrontSend do
  @moduledoc """
  Core tool: delivers a message to the open front screen's `handle_info/2`,
  the way a plugin's reply or a timer reaches it (`Operator.Core.Front.deliver/3`).
  A camera, photo picker, scanner or NFC path otherwise needs a person at
  the phone; with this the agent tests it itself: send the reply the plugin
  would, then `front_screenshot`.

  The message is an Elixir literal, parsed but never evaluated: only atoms,
  numbers, strings, lists, tuples and maps get through, and only atoms that
  already exist (a screen can only match atoms in its code, so a new one is
  a typo). A file path in a capability reply (`{:camera, :photo, %{path:
  ...}}`, ...) names a file in the workspace; it is copied into the app's
  temporary files first (`Operator.Core.Files.stage_capability/2`), so the
  screen's `Files.keep/2` takes it as it would the phone's own result.
  Acts on `ctx[:front]` if given.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Files
  alias Operator.Core.Front
  alias Operator.Core.Tools.FrontTap

  @max_message 4_000

  @impl true
  def name, do: "front_send"

  @impl true
  def description,
    do:
      "Deliver a message to the open front screen's handle_info/2, exactly as a plugin " <>
        "reply, permission answer or timer would. This is how you test a camera, photo " <>
        "picker, scanner, NFC, notification or any other async-result path without a " <>
        "person: send the reply the plugin would send, then front_screenshot. `message` is " <>
        "an Elixir literal (atoms, numbers, strings, lists, tuples, maps; no calls or " <>
        "variables), e.g. `{:camera, :photo, %{path: \"inbox/x.jpg\", width: 600, height: 200}}`. " <>
        "Get the exact shape from the plugin's doc (read_doc MobCamera, MobPhotos, ...) or " <>
        "the screen's handle_info clauses. A `path:` in a camera/photos/files/audio reply is " <>
        "a file in your workspace; the screen gets a fresh copy where the phone would put " <>
        "one, so Files.keep/2 works on it. Says whether the screen re-rendered."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_message,
          "description" => "An Elixir term literal, e.g. {:photos, :picked, [%{path: \"a.jpg\"}]}"
        }
      },
      "required" => ["message"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 10_000

  # The front has one screen: no other front call runs alongside.
  @impl true
  def concurrency, do: :exclusive

  @impl true
  def run(%{"message" => text}, ctx) when is_binary(text) do
    with {:ok, message} <- parse(text),
         {:ok, message} <- Files.stage_capability(message, ctx) do
      case Front.deliver(message, Map.get(ctx, :front, Front)) do
        {:ok, screen, outcome} ->
          "Sent #{inspect(message, limit: 8, printable_limit: 120)} to #{screen}"
          |> FrontTap.outcome(outcome)
          |> FrontTap.covered(ctx)

        {:error, :not_running} ->
          {:error, "No front screen is running: open one with front_open first."}
      end
    end
  end

  def run(_args, _ctx), do: {:error, "`message` is required"}

  @doc """
  Parses `text` as an Elixir literal: `{:ok, term}`, or `{:error, text}`
  naming what isn't one (a call, a variable, an atom no code has).
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(text) do
    case Code.string_to_quoted(text, existing_atoms_only: true) do
      {:ok, ast} ->
        literal(ast)

      {:error, {_meta, "unsafe atom does not exist: " <> _, atom}} ->
        {:error, "unknown atom #{atom}: no code uses it, so no screen can match it (a typo?)"}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, 1), else: 1
        {:error, "not valid Elixir (line #{line}): #{error_text(message)}#{token}"}
    end
  end

  defp error_text({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp error_text(message), do: to_string(message)

  # Atoms, numbers, strings and two-element tuples are their own AST.
  defp literal(x) when is_atom(x) or is_number(x) or is_binary(x), do: {:ok, x}

  defp literal(list) when is_list(list), do: all(list)

  defp literal({a, b}) do
    with {:ok, a} <- literal(a), {:ok, b} <- literal(b), do: {:ok, {a, b}}
  end

  defp literal({:{}, _meta, elements}) when is_list(elements) do
    with {:ok, elements} <- all(elements), do: {:ok, List.to_tuple(elements)}
  end

  defp literal({:%{}, _meta, pairs}) when is_list(pairs) do
    with {:ok, pairs} <- all(pairs) do
      if Enum.all?(pairs, &match?({_, _}, &1)),
        do: {:ok, Map.new(pairs)},
        else: {:error, "a map needs key => value pairs"}
    end
  end

  # A negative number.
  defp literal({:-, _meta, [n]}) when is_number(n), do: {:ok, -n}

  # A literal in parentheses.
  defp literal({:__block__, _meta, [single]}), do: literal(single)

  # A module name, if one by that name exists (`Operator.Dyn.Home`).
  defp literal({:__aliases__, _meta, parts} = ast) do
    name = "Elixir." <> Enum.map_join(parts, ".", &to_string/1)

    if Enum.all?(parts, &is_atom/1) do
      {:ok, String.to_existing_atom(name)}
    else
      {:error, "`#{Macro.to_string(ast)}` is not a literal"}
    end
  rescue
    ArgumentError -> {:error, "unknown module #{Macro.to_string(ast)}"}
  end

  defp literal({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: {:error, "`#{name}` is a variable; write the value itself"}

  defp literal({:^, _meta, _args}), do: {:error, "a pin (^) is not a literal"}

  defp literal(other) do
    {:error,
     "`#{other |> Macro.to_string() |> String.slice(0, 80)}` is not a literal: only atoms, " <>
       "numbers, strings, lists, tuples and maps (no calls, variables or structs)"}
  end

  defp all(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @impl true
  def selftest do
    with {:ok, {:camera, :photo, %{path: "a.jpg", width: 2}}} <-
           parse(~s|{:camera, :photo, %{path: "a.jpg", width: 2}}|),
         {:error, "`File.rm(\"x\")` is not a literal" <> _} <- parse(~s|File.rm("x")|),
         {:error, "unknown atom" <> _} <- parse(":operator_front_send_no_such_atom_x9") do
      :ok
    end
  end
end
