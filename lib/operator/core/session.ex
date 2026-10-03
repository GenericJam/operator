defmodule Operator.Core.Session do
  @moduledoc """
  Sessions in omp/pi's JSONL format (`pi-coding-agent/src/session/
  session-entries.ts`, `CURRENT_SESSION_VERSION = 3`), so a session can move
  between omp on a computer and Operator on the phone.

  A file is a `session` header line, then entries. Every entry carries `type`,
  `id` (8 hex chars), `parentId` (the previous entry; entries form a tree and
  the last entry is the leaf) and an ISO `timestamp`. Operator writes:

    * `model_change` (`model` as `"provider/modelId"`), first, and on a switch
    * `message` with pi's `AgentMessage` in `message`: `user`, `assistant`
      (text / thinking / toolCall content, `api`, `provider`, `model`,
      `usage`, `stopReason`, `errorMessage`), `toolResult`
    * `custom_message` (`customType` `"operator.notice"` / `"operator.error"` /
      `"operator.aside"`, `content`, `display`) for loop notices

  Reading keeps every entry, including types Operator doesn't know (omp's
  `custom`, `compaction`, `title_change`, `thinking_level_change`, …). They
  are carried along (Operator only appends, never rewrites) and ignored
  when building the model context: `context/1` walks the leaf's branch and
  turns `message` and `custom_message` entries into req_llm messages.

  The loop builds every request with `context/1` over its entry list, and
  `append/2` returns the entry as it reads back from disk, so a resumed
  session sends exactly what the live one did.
  """

  alias ReqLLM.Context
  alias ReqLLM.ToolCall

  require Logger

  @version 3
  @aborted_tool_text "Tool was not executed because the run was aborted."

  defstruct [:id, :path, :cwd, :model, :title, leaf_id: nil, written?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          cwd: String.t(),
          model: String.t(),
          title: String.t() | nil,
          leaf_id: String.t() | nil,
          written?: boolean()
        }
  @type entry :: %{String.t() => term()}

  @doc "Where Operator's sessions live: `<data dir>/sessions`."
  @spec dir() :: String.t()
  def dir, do: Path.join(Operator.Paths.data_dir(), "sessions")

  @doc """
  A new session in `dir` for `model` (a req_llm spec, `"openrouter:…"`).
  Nothing is written until the first `append/2`, which writes the header
  (titled after the first user message) and a `model_change` entry.
  """
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(dir, model, cwd) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    id = uuid_v7(now)
    stamp = now |> DateTime.to_iso8601() |> String.replace(":", "-") |> String.replace(".", "-")
    %__MODULE__{id: id, path: Path.join(dir, "#{stamp}_#{id}.jsonl"), cwd: cwd, model: model}
  end

  @doc """
  Reads a session file: returns the session and the entries on the leaf's
  branch, oldest first. Unknown entry types are kept; unparsable lines (a
  torn last write) are skipped and logged.
  """
  @spec open(String.t(), String.t()) :: {:ok, t(), [entry()]} | {:error, term()}
  def open(path, default_model) do
    with {:ok, body} <- File.read(path),
         {[%{"type" => "session", "id" => id} = header], entries} <-
           split_header(decode_lines(body, path)) do
      branch = branch(entries)
      leaf = List.last(branch)

      session = %__MODULE__{
        id: id,
        path: path,
        cwd: header["cwd"],
        title: header["title"],
        leaf_id: leaf && leaf["id"],
        written?: true,
        model: model_from(branch) || default_model
      }

      {:ok, session, branch}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_a_session}
    end
  end

  @doc """
  Appends one entry (adding `id`, `parentId`, `timestamp`). Returns the
  updated session and the entry as it reads back from disk.
  """
  @spec append(t(), entry()) :: {t(), entry()}
  def append(%__MODULE__{written?: false} = s, entry) do
    File.mkdir_p!(Path.dirname(s.path))
    title = title_for(entry)

    header = %{
      "type" => "session",
      "version" => @version,
      "id" => s.id,
      "timestamp" => now_iso(),
      "cwd" => s.cwd,
      "title" => title,
      "titleSource" => "auto"
    }

    File.write!(s.path, [Jason.encode!(header), ?\n])
    {s, _} = append(%{s | written?: true, title: title}, model_change(s.model))
    append(s, entry)
  end

  def append(%__MODULE__{} = s, entry) when is_map(entry) do
    base = %{"id" => short_id(), "parentId" => s.leaf_id, "timestamp" => now_iso()}
    line = entry |> Map.merge(base) |> Jason.encode!()
    File.write!(s.path, [line, ?\n], [:append])
    written = Jason.decode!(line)
    model = if entry["type"] == "model_change", do: from_pi_model(entry["model"]), else: s.model
    {%{s | leaf_id: written["id"], model: model}, written}
  end

  @doc "Sessions in `dir`, most recently written first."
  @spec list(String.t()) :: [
          %{id: String.t(), path: String.t(), mtime: integer(), title: String.t() | nil}
        ]
  def list(dir) do
    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_header(path) do
        %{"type" => "session", "id" => id} = header ->
          [
            %{
              id: id,
              path: path,
              mtime: File.stat!(path, time: :posix).mtime,
              title: header["title"]
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.mtime, &1.path}, :desc)
  end

  @doc "Path of the most recently written session in `dir`, or nil."
  @spec latest(String.t()) :: String.t() | nil
  def latest(dir) do
    case list(dir) do
      [%{path: path} | _] -> path
      [] -> nil
    end
  end

  # ── entry builders (pi shapes; id/parentId/timestamp added by append/2) ──

  @spec user(String.t(), keyword()) :: entry()
  def user(text, opts \\ []) do
    message = %{
      "role" => "user",
      "content" => [text_part(text)],
      "attribution" => "user",
      "timestamp" => now_ms()
    }

    message = if opts[:steering], do: Map.put(message, "steering", true), else: message
    %{"type" => "message", "message" => message}
  end

  @doc """
  An assistant message. `reply` has `:text`, `:thinking`, `:tool_calls`
  (`[%{"id", "name", "arguments"}]`), `:usage` (req_llm's usage map or nil),
  `:stop_reason` (pi's: `"stop" | "length" | "toolUse" | "error" |
  "aborted"`) and optionally `:error`.
  """
  @spec assistant(map(), String.t()) :: entry()
  def assistant(reply, model) do
    {provider, model_id} = split_model(model)

    content =
      [
        reply[:thinking] not in [nil, ""] && %{"type" => "thinking", "thinking" => reply.thinking},
        reply[:text] not in [nil, ""] && text_part(reply.text)
        | for(c <- reply[:tool_calls] || [], do: Map.put(c, "type", "toolCall"))
      ]
      |> Enum.filter(& &1)

    message = %{
      "role" => "assistant",
      "content" => content,
      "api" => provider,
      "provider" => provider,
      "model" => model_id,
      "usage" => pi_usage(reply[:usage]),
      "stopReason" => reply.stop_reason,
      "timestamp" => now_ms()
    }

    message = if reply[:error], do: Map.put(message, "errorMessage", reply.error), else: message
    %{"type" => "message", "message" => message}
  end

  @spec tool_result(String.t(), String.t(), String.t(), boolean()) :: entry()
  def tool_result(call_id, name, text, is_error) do
    %{
      "type" => "message",
      "message" => %{
        "role" => "toolResult",
        "toolCallId" => call_id,
        "toolName" => name,
        "content" => [text_part(text)],
        "isError" => is_error,
        "timestamp" => now_ms()
      }
    }
  end

  @doc "A loop notice: `kind` is `:notice`, `:error` or `:aside`."
  @spec custom(atom(), String.t()) :: entry()
  def custom(kind, text) when kind in [:notice, :error, :aside] do
    %{
      "type" => "custom_message",
      "customType" => "operator.#{kind}",
      "content" => text,
      "display" => true,
      "attribution" => "agent"
    }
  end

  @doc "Records a model switch; `model` is a req_llm spec (`\"openrouter:…\"`)."
  @spec model_change(String.t()) :: entry()
  def model_change(model), do: %{"type" => "model_change", "model" => to_pi_model(model)}

  # ── reading entries ──

  @doc "The text of a message's content (string or parts; text parts only)."
  @spec text(term()) :: String.t()
  def text(content) when is_binary(content), do: content

  def text(content) when is_list(content),
    do: Enum.map_join(for(%{"type" => "text", "text" => t} <- content, do: t), "", & &1)

  def text(_), do: ""

  @doc "Thinking text of an assistant message."
  @spec thinking(map()) :: String.t()
  def thinking(%{"content" => content}) when is_list(content),
    do: Enum.map_join(for(%{"type" => "thinking", "thinking" => t} <- content, do: t), "", & &1)

  def thinking(_), do: ""

  @doc ~S|Tool calls of an assistant message: `[%{"id", "name", "arguments"}]`.|
  @spec tool_calls(map()) :: [map()]
  def tool_calls(%{"content" => content}) when is_list(content),
    do: for(%{"type" => "toolCall"} = c <- content, do: c)

  def tool_calls(_), do: []

  # ── replay ──

  @doc """
  The req_llm messages for a branch (no system prompt). `message` and
  `custom_message` entries contribute; every other type is ignored.
  Assistant turns with no text and no tool calls (empty errors / aborts)
  and pi's superseded `retryRecovery` turns are dropped, and a tool call
  left without a result gets pi's synthetic "aborted" result, so the
  context is always valid for the provider.
  """
  @spec context([entry()]) :: [ReqLLM.Message.t()]
  def context(entries) do
    entries
    |> Enum.flat_map(&to_messages/1)
    |> close_dangling_calls()
  end

  defp to_messages(%{"type" => "message", "message" => %{"role" => role} = m})
       when role in ["user", "developer"] do
    case text(m["content"]) do
      "" -> []
      text -> [Context.user(text)]
    end
  end

  defp to_messages(%{"type" => "message", "message" => %{"role" => "assistant"} = m}) do
    calls =
      for c <- tool_calls(m),
          do: ToolCall.new(c["id"], c["name"], Jason.encode!(c["arguments"] || %{}))

    text = text(m["content"])

    if (text == "" and calls == []) or Map.has_key?(m, "retryRecovery"),
      do: [],
      else: [Context.assistant(text, tool_calls: calls)]
  end

  defp to_messages(%{"type" => "message", "message" => %{"role" => "toolResult"} = m}),
    do: [Context.tool_result(m["toolCallId"], m["toolName"], text(m["content"]))]

  defp to_messages(%{"type" => "custom_message", "content" => content}) do
    case text(content) do
      "" -> []
      text -> [Context.user(text)]
    end
  end

  defp to_messages(_entry), do: []

  defp close_dangling_calls(messages) do
    {out, open} = Enum.reduce(messages, {[], []}, &track_calls/2)
    Enum.reverse(synthetic_results(open) ++ out)
  end

  defp track_calls(%{role: :tool, tool_call_id: id} = msg, {acc, open}),
    do: {[msg | acc], Enum.reject(open, &(elem(&1, 0) == id))}

  defp track_calls(msg, {acc, open}) do
    calls = for %ToolCall{id: id, function: %{name: name}} <- msg.tool_calls || [], do: {id, name}
    {[msg | synthetic_results(open) ++ acc], calls}
  end

  # `open` is in call order; the results come back reversed because they
  # are prepended to the reversed accumulator.
  defp synthetic_results(open),
    do:
      open
      |> Enum.reverse()
      |> Enum.map(fn {id, name} -> Context.tool_result(id, name, @aborted_tool_text) end)

  @doc "The text pi uses for a tool call that never ran."
  @spec aborted_tool_text() :: String.t()
  def aborted_tool_text, do: @aborted_tool_text

  @doc """
  The req_llm model spec in effect on a branch: the last default-role
  `model_change`, else the last assistant's provider/model, else nil.
  """
  @spec model_from([entry()]) :: String.t() | nil
  def model_from(entries) do
    explicit =
      for %{"type" => "model_change", "model" => m} = e <- entries,
          (e["role"] || "default") == "default",
          do: m

    inferred =
      for %{
            "type" => "message",
            "message" => %{"role" => "assistant", "provider" => p, "model" => m}
          } <- entries,
          do: "#{p}/#{m}"

    case List.last(explicit) || List.last(inferred) do
      nil -> nil
      pi_model -> from_pi_model(pi_model)
    end
  end

  @doc "Summed usage over a branch's assistant messages (pi `usage` shape)."
  @spec totals([entry()]) :: %{
          tokens: non_neg_integer(),
          output: non_neg_integer(),
          cost: float()
        }
  def totals(entries) do
    Enum.reduce(entries, %{tokens: 0, output: 0, cost: 0.0}, fn
      %{"type" => "message", "message" => %{"role" => "assistant", "usage" => %{} = u}}, acc ->
        add_usage(acc, u)

      _, acc ->
        acc
    end)
  end

  @spec add_usage(map(), map()) :: map()
  def add_usage(acc, u) do
    %{
      tokens: acc.tokens + (u["totalTokens"] || 0),
      output: acc.output + (u["output"] || 0),
      cost: acc.cost + (get_in(u, ["cost", "total"]) || 0) * 1.0
    }
  end

  @doc ~S|`"openrouter:anthropic/x"` (req_llm) → `"openrouter/anthropic/x"` (pi).|
  @spec to_pi_model(String.t()) :: String.t()
  def to_pi_model(spec), do: String.replace(spec, ":", "/", global: false)

  @doc ~S|`"openrouter/anthropic/x"` (pi) → `"openrouter:anthropic/x"` (req_llm).|
  @spec from_pi_model(String.t()) :: String.t()
  def from_pi_model(pi_model), do: String.replace(pi_model, "/", ":", global: false)

  # ── helpers ──

  @doc """
  The leaf's branch: from the last entry with an id, follow `parentId` to
  the root. Entries without an id (pi's title slot) are not on any branch.
  """
  @spec branch([entry()]) :: [entry()]
  def branch(entries) do
    with_ids = Enum.filter(entries, &is_binary(&1["id"]))
    by_id = Map.new(with_ids, &{&1["id"], &1})

    case List.last(with_ids) do
      nil -> []
      leaf -> walk(leaf, by_id, MapSet.new(), [])
    end
  end

  defp walk(entry, by_id, seen, acc) do
    acc = [entry | acc]
    seen = MapSet.put(seen, entry["id"])
    parent = entry["parentId"] && Map.get(by_id, entry["parentId"])

    if parent && not MapSet.member?(seen, parent["id"]),
      do: walk(parent, by_id, seen, acc),
      else: acc
  end

  defp split_header(entries), do: Enum.split_with(entries, &(&1["type"] == "session"))

  defp decode_lines(body, path) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = entry} when is_binary(type) and type != "title" ->
          [entry]

        {:ok, %{"type" => "title"}} ->
          []

        other ->
          Logger.warning(
            "[session] skipping unreadable line in #{Path.basename(path)}: #{inspect(other, limit: 5)}"
          )

          []
      end
    end)
  end

  defp read_header(path) do
    path
    |> File.stream!()
    |> Enum.take(2)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "session"} = header} -> header
        _ -> nil
      end
    end)
  end

  defp title_for(%{"type" => "message", "message" => %{"role" => "user", "content" => c}}),
    do: c |> text() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 60)

  defp title_for(_entry), do: ""

  defp split_model(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {provider, id}
      [id] -> {"openrouter", id}
    end
  end

  defp pi_usage(nil), do: pi_usage(%{})

  defp pi_usage(u) do
    cache_read = u[:cache_read_tokens] || u[:cached_tokens] || 0
    cache_write = u[:cache_write_tokens] || u[:cache_creation_tokens] || 0
    input = max((u[:input_tokens] || 0) - cache_read - cache_write, 0)
    output = u[:output_tokens] || 0

    %{
      "input" => input,
      "output" => output,
      "cacheRead" => cache_read,
      "cacheWrite" => cache_write,
      "totalTokens" => input + output + cache_read + cache_write,
      "cost" => %{
        "input" => num(u[:input_cost]),
        "output" => num(u[:output_cost]),
        "cacheRead" => 0,
        "cacheWrite" => 0,
        "total" => num(u[:total_cost] || u[:cost])
      }
    }
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp text_part(text), do: %{"type" => "text", "text" => text}

  defp short_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp now_ms, do: System.os_time(:millisecond)

  # RFC 9562 UUIDv7: 48-bit Unix ms, version 7, variant 10, random rest.
  defp uuid_v7(now) do
    ms = DateTime.to_unix(now, :millisecond)
    <<a::12, b::62, _::6>> = :crypto.strong_rand_bytes(10)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<ms::48, 7::4, a::12, 2::2, b::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
