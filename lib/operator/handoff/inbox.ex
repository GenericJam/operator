defmodule Operator.Handoff.Inbox do
  @moduledoc """
  Collects the parts of a handoff (`Operator.Handoff.parse/1`) until its
  set is complete: in any order, a part already in is ignored, sets with
  different ids don't mix. A set no part has joined for 30 minutes is
  dropped.

  A process rather than state in a screen: parts come from whichever
  screen is showing when a link arrives (the chat, or the scanner), and a
  set has to outlive the app being killed between two scans. So one
  process owns the sets and keeps them on disk, `<data dir>/
  handoff_inbox.json`, rewritten on every change.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:dir` (default
  `Operator.Paths.data_dir/0`).
  """
  use GenServer

  alias Operator.Handoff

  require Logger

  @expire_ms 30 * 60_000
  @file_name "handoff_inbox.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Adds a part. `{:partial, received, total}` while parts are missing (a
  duplicate leaves the count as it was); the last one gives the assembled
  handoff and clears its set. `opts`: `:server`, `:now` (ms, for the
  30-minute expiry).
  """
  @spec put(Handoff.part(), keyword()) ::
          {:partial, pos_integer(), pos_integer()}
          | {:complete, Handoff.t()}
          | {:error, :mixed_parts | :corrupt | :unsupported_version}
  def put(part, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:millisecond) end)
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:put, part, now})
  end

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &Operator.Paths.data_dir/0)
    path = Path.join(dir, @file_name)
    {:ok, %{path: path, sets: load(path)}}
  end

  @impl true
  def handle_call({:put, part, now}, _from, s) do
    sets = for {id, set} <- s.sets, now - set["seen"] <= @expire_ms, into: %{}, do: {id, set}
    set = Map.get(sets, part.id, %{"total" => part.total, "parts" => %{}})

    if set["total"] == part.total do
      parts = Map.put_new(set["parts"], Integer.to_string(part.index), part.data)
      set = %{set | "parts" => parts} |> Map.put("seen", now)
      {reply, sets} = add(sets, part.id, set)
      {:reply, reply, %{s | sets: save(s.path, sets)}}
    else
      {:reply, {:error, :mixed_parts}, %{s | sets: save(s.path, sets)}}
    end
  end

  defp add(sets, id, %{"total" => total, "parts" => parts}) when map_size(parts) == total do
    chunks = for i <- 1..total, do: Map.fetch!(parts, Integer.to_string(i))

    case Handoff.assemble(id, chunks) do
      {:ok, handoff} -> {{:complete, handoff}, Map.delete(sets, id)}
      {:error, _} = error -> {error, Map.delete(sets, id)}
    end
  end

  defp add(sets, id, set),
    do: {{:partial, map_size(set["parts"]), set["total"]}, Map.put(sets, id, set)}

  # ── the file ──

  # Written whole, through a temporary file, so a kill mid-write leaves the
  # previous version.
  defp save(path, sets) when map_size(sets) == 0 do
    _ = File.rm(path)
    sets
  end

  defp save(path, sets) do
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, Jason.encode!(sets))
    File.rename!(tmp, path)
    sets
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = sets} <- Jason.decode(body) do
      for {id, set} <- sets, valid?(set), into: %{}, do: {id, set}
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning(
          "[handoff] ignoring an unreadable #{@file_name}: #{inspect(other, limit: 5)}"
        )

        %{}
    end
  end

  defp valid?(%{"total" => total, "seen" => seen, "parts" => %{} = parts})
       when is_integer(total) and total > 0 and is_integer(seen) do
    Enum.all?(parts, fn {i, data} -> is_binary(data) and index?(i, total) end)
  end

  defp valid?(_set), do: false

  defp index?(i, total) do
    case Integer.parse(i) do
      {n, ""} -> n >= 1 and n <= total
      _ -> false
    end
  end
end
