defmodule Operator.Core.Tools.Friction do
  @moduledoc """
  Core tool: the agent's friction log, kept across sessions in the app's
  data dir (`friction.jsonl`, private, not the workspace). An entry is
  something in the environment that cost the agent time: a doc missing,
  wrong or unclear, an error it couldn't read, a tool it lacked, a guess
  that failed. The agent clears what it can itself (a helper or a note in
  its Dyn layer) and marks it resolved; the open ones are for the user's
  Mac, which reads the file to fix docs, prompts and Core.
  """
  @behaviour Operator.Core.Tool

  @file_name "friction.jsonl"
  @max_text 600

  @impl true
  def name, do: "friction"

  @impl true
  def description do
    "Your friction log, kept across sessions. action=log records something in this " <>
      "environment that cost you time (`what` happened, `would_help`: the doc, tool or " <>
      "error message that would have saved it); action=list shows the entries (open ones " <>
      "first; `all: true` includes resolved); action=resolve marks entry `id` resolved, " <>
      "`how`: what you changed."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["log", "list", "resolve"]},
        "what" => %{"type" => "string", "maxLength" => @max_text},
        "would_help" => %{"type" => "string", "maxLength" => @max_text},
        "id" => %{"type" => "integer", "minimum" => 1},
        "how" => %{"type" => "string", "maxLength" => @max_text},
        "all" => %{"type" => "boolean"}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"action" => "log", "what" => what} = args, ctx) when is_binary(what) and what != "" do
    entries = read(ctx)
    id = length(entries) + 1

    entry = %{
      "id" => id,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "session" => ctx[:session_id],
      "what" => clip(what),
      "would_help" => clip(args["would_help"] || "")
    }

    :ok = File.write(path(ctx), [JSON.encode!(entry), ?\n], [:append])
    open = Enum.count(entries, &is_nil(&1["resolved"])) + 1
    {:ok, "Logged as ##{id}. #{open} open."}
  end

  def run(%{"action" => "log"}, _ctx), do: {:error, "log needs a non-empty `what`"}

  def run(%{"action" => "list"} = args, ctx) do
    entries = read(ctx)
    shown = if args["all"], do: entries, else: Enum.filter(entries, &is_nil(&1["resolved"]))

    case shown do
      [] -> {:ok, if(entries == [], do: "(no friction logged)", else: "(nothing open)")}
      list -> {:ok, Enum.map_join(list, "\n", &line/1)}
    end
  end

  def run(%{"action" => "resolve", "id" => id, "how" => how}, ctx)
      when is_integer(id) and is_binary(how) and how != "" do
    entries = read(ctx)

    if Enum.any?(entries, &(&1["id"] == id)) do
      updated = Enum.map(entries, &resolve(&1, id, clip(how)))

      body = Enum.map(updated, &[JSON.encode!(&1), ?\n])
      tmp = path(ctx) <> ".tmp"
      :ok = File.write(tmp, body)
      :ok = File.rename(tmp, path(ctx))
      {:ok, "##{id} resolved."}
    else
      {:error, "no entry ##{id}"}
    end
  end

  def run(%{"action" => "resolve"}, _ctx),
    do: {:error, "resolve needs `id` and a non-empty `how`"}

  def run(args, _ctx),
    do: {:error, "unknown action: #{inspect(args["action"])}; use log, list or resolve"}

  @impl true
  def selftest do
    dir = Path.join(System.tmp_dir!(), "operator-friction-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ctx = %{data_dir: dir, session_id: "s"}

    try do
      with {:ok, "(no friction logged)"} <- run(%{"action" => "list"}, ctx),
           {:ok, "Logged as #1. 1 open."} <-
             run(%{"action" => "log", "what" => "w", "would_help" => "h"}, ctx),
           {:ok, "#1 resolved."} <- run(%{"action" => "resolve", "id" => 1, "how" => "x"}, ctx),
           {:ok, "(nothing open)"} <- run(%{"action" => "list"}, ctx) do
        :ok
      else
        other -> {:error, other}
      end
    after
      File.rm_rf!(dir)
    end
  end

  @doc "Every entry, oldest first (for the Mac, over RPC, and for tests)."
  @spec entries(String.t()) :: [map()]
  def entries(data_dir \\ Operator.Paths.data_dir()), do: read(%{data_dir: data_dir})

  defp read(ctx) do
    case File.read(path(ctx)) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _} -> []
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{"id" => _} = e} -> [e]
      _ -> []
    end
  end

  defp resolve(%{"id" => id} = e, id, how), do: Map.put(e, "resolved", how)
  defp resolve(e, _id, _how), do: e

  defp line(e) do
    resolved = if e["resolved"], do: " [resolved: #{e["resolved"]}]", else: ""
    help = if e["would_help"] in [nil, ""], do: "", else: " (would help: #{e["would_help"]})"
    "##{e["id"]} #{String.slice(e["at"] || "", 0, 10)} #{e["what"]}#{help}#{resolved}"
  end

  defp clip(text), do: text |> String.trim() |> String.slice(0, @max_text)
  defp path(ctx), do: Path.join(ctx.data_dir, @file_name)
end
