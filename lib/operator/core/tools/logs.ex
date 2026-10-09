defmodule Operator.Core.Tools.Logs do
  @moduledoc """
  Core tool: the phone's recent `Logger` output, from the in-memory ring
  `Operator.Core.LogRing` keeps (the last 1,000 events since launch). It is
  how the agent sees the crash behind a screen that froze, a tool that
  failed quietly or a plugin's error, without a Mac on adb.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.LogRing

  @levels ~w(debug info warning error)
  @default_limit 100
  @max_limit 500
  # The newest lines that fit; the loop spills a longer result to an
  # artifact anyway, this keeps one call from carrying the whole ring.
  @max_bytes 48_000

  @impl true
  def name, do: "logs"

  @impl true
  def description do
    "Recent Logger output on this phone (the last 1,000 events since the app started), " <>
      "newest last, each starting `HH:MM:SS.mmm [level] message` (a crash report spans " <>
      "lines). " <>
      "Read it after a crash, a screen or tool that failed silently, or a plugin error: " <>
      "crash reports, the Dyn layer's messages and your own Logger calls land here. " <>
      "Filter by minimum `level`, `grep` (case-insensitive regex, or plain substring) " <>
      "and `since_seconds`."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "level" => %{
          "type" => "string",
          "enum" => @levels,
          "description" => "Minimum level (default info)."
        },
        "grep" => %{
          "type" => "string",
          "description" => "Keep lines matching this case-insensitive regex (or substring)."
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_limit,
          "description" =>
            "The newest N matching lines (default #{@default_limit}, max #{@max_limit})."
        },
        "since_seconds" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "Only lines from the last N seconds."
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(args, _ctx), do: query(args, LogRing)

  @doc false
  # `run/2` against the ring in `table`.
  @spec query(map(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  def query(args, table) do
    with {:ok, opts} <- options(args) do
      case LogRing.recent(opts, table) do
        {:ok, []} -> {:ok, "(no log lines match)"}
        {:ok, entries} -> {:ok, render(entries)}
        {:error, :not_running} -> {:error, "the log ring isn't running on this launch"}
      end
    end
  end

  defp options(args) do
    with {:ok, level} <- level(Map.get(args, "level", "info")),
         {:ok, limit} <- limit(Map.get(args, "limit", @default_limit)),
         {:ok, since} <- since(Map.get(args, "since_seconds")),
         {:ok, grep} <- grep(Map.get(args, "grep")) do
      {:ok, [level: level, limit: limit, since_us: since, grep: grep]}
    end
  end

  defp level(l) when l in @levels, do: {:ok, String.to_existing_atom(l)}

  defp level(l),
    do: {:error, "level must be one of #{Enum.join(@levels, ", ")}, got #{inspect(l)}"}

  defp limit(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_limit)}
  defp limit(n), do: {:error, "limit must be a positive integer, got #{inspect(n)}"}

  defp since(nil), do: {:ok, nil}

  defp since(s) when is_integer(s) and s > 0,
    do: {:ok, :os.system_time(:microsecond) - s * 1_000_000}

  defp since(s), do: {:error, "since_seconds must be a positive integer, got #{inspect(s)}"}

  defp grep(nil), do: {:ok, nil}
  defp grep(g) when is_binary(g), do: {:ok, g}
  defp grep(g), do: {:error, "grep must be a string, got #{inspect(g)}"}

  # Newest lines kept when they don't all fit.
  defp render(entries) do
    {kept, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn %{line: line}, {acc, bytes} ->
        bytes = bytes + byte_size(line) + 1

        if bytes > @max_bytes and acc != [],
          do: {:halt, {acc, bytes}},
          else: {:cont, {[line | acc], bytes}}
      end)

    dropped = length(entries) - length(kept)

    note =
      if dropped > 0,
        do: ["(#{dropped} older matching lines left out; narrow the filter)\n"],
        else: []

    IO.iodata_to_binary([note, Enum.intersperse(kept, "\n")])
  end

  @impl true
  def selftest do
    table = :"#{__MODULE__}.Selftest#{System.unique_integer([:positive])}"
    LogRing.new_table(table)
    config = %{config: %{table: table, max: 3}}

    try do
      for {level, text} <- [
            info: "one",
            error: "two boom",
            debug: "three",
            info: "four",
            warning: "five"
          ] do
        LogRing.log(%{level: level, msg: {:string, text}, meta: %{}}, config)
      end

      with {:ok, all} <- query(%{"level" => "debug"}, table),
           ["three", "four", "five"] <- Enum.map(String.split(all, "\n"), &last_word/1),
           {:ok, "(no log lines match)"} <- query(%{"grep" => "boom"}, table),
           {:ok, five} <- query(%{"level" => "warning"}, table),
           true <- five =~ "[warning] five" do
        :ok
      else
        other -> {:error, other}
      end
    after
      :ets.delete(table)
    end
  end

  defp last_word(line), do: line |> String.split(" ") |> List.last()
end
