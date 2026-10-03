defmodule Operator.Core.Tools.Clipboard do
  @moduledoc """
  Core tool: read or set the phone's clipboard text. Android only lets the
  app in front read the clipboard, so a read while Operator runs in the
  background comes back empty.
  """
  @behaviour Operator.Core.Tool

  @max_chars 100_000

  @impl true
  def name, do: "clipboard"

  @impl true
  def description do
    "Read the phone's clipboard text (action=read) or put text on it (action=write, " <>
      "with `text`), e.g. a command or snippet for the user to paste elsewhere."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["read", "write"]},
        "text" => %{"type" => "string", "description" => "What to put on the clipboard (write)."}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  # `ctx[:clipboard]` is `{get_fun, put_fun}` in tests; the phone's by default.
  @impl true
  def run(%{"action" => "read"}, ctx) do
    {get, _put} = native(ctx)

    case get.() do
      {:ok, text} -> {:ok, text}
      :empty -> {:ok, "(the clipboard is empty, or Operator isn't in front so Android hides it)"}
      {:error, reason} -> {:error, "could not read the clipboard: #{inspect(reason)}"}
    end
  end

  def run(%{"action" => "write", "text" => text}, ctx) when is_binary(text) do
    cond do
      text == "" ->
        {:error, "write needs a non-empty `text`"}

      String.length(text) > @max_chars ->
        {:error, "text is over #{@max_chars} characters"}

      true ->
        {_get, put} = native(ctx)

        case put.(text) do
          :ok -> {:ok, "Copied #{String.length(text)} characters to the clipboard."}
          {:error, reason} -> {:error, "could not set the clipboard: #{inspect(reason)}"}
        end
    end
  end

  def run(%{"action" => "write"}, _ctx), do: {:error, "write needs `text`"}

  def run(args, _ctx),
    do: {:error, "unknown action: #{inspect(args["action"])}; use read or write"}

  defp native(ctx), do: Map.get(ctx, :clipboard, {&get/0, &put/1})

  defp get do
    :mob_nif.clipboard_get()
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  defp put(text) do
    _ = :mob_nif.clipboard_put(text)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def selftest do
    store = :atomics.new(1, [])

    fake =
      {fn -> if :atomics.get(store, 1) == 1, do: {:ok, "x"}, else: :empty end,
       fn _ -> :atomics.put(store, 1, 1) end}

    with {:ok, "Copied 1 characters to the clipboard."} <-
           run(%{"action" => "write", "text" => "x"}, %{clipboard: fake}),
         {:ok, "x"} <- run(%{"action" => "read"}, %{clipboard: fake}) do
      :ok
    else
      other -> {:error, "selftest: #{inspect(other)}"}
    end
  end
end
