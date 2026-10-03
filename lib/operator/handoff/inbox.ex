defmodule Operator.Handoff.Inbox do
  @moduledoc """
  Collects the parts of a handoff (`Operator.Handoff.parse/1`) until its
  set is complete: in any order, a part already in is ignored, sets with
  different ids don't mix. A part that gives its set another part count
  starts the set over from that part, so a bad scan can't lock the real
  codes out.

  A process rather than state in a screen: parts come from whichever
  screen is showing when a link arrives (the chat, or the scanner), and a
  set has to outlive the app being killed between two scans. So one
  process owns the sets and keeps them on disk, `<data dir>/
  handoff_inbox.json`, rewritten on every change.

  Links can come from anyone's QR, so what is kept is bounded: a set no
  part has joined for 30 minutes is dropped (checked at start, with every
  part and every minute), and past 8 sets or 512,000 bytes of parts the
  sets least recently joined go first.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:dir` (default
  `Operator.Paths.data_dir/0`), `:clock` (a function giving the time in
  ms), `:max_bytes`, `:prune_ms`.
  """
  use GenServer

  alias Operator.Handoff

  require Logger

  @expire_ms 30 * 60_000
  @prune_ms 60_000
  @max_sets 8
  @max_bytes 512_000
  @file_name "handoff_inbox.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Adds a part. `{:partial, received, total}` while parts are missing (a
  duplicate leaves the count as it was); the last one gives the assembled
  handoff and clears its set. `opts`: `:server`.
  """
  @spec put(Handoff.part(), keyword()) ::
          {:partial, pos_integer(), pos_integer()}
          | {:complete, Handoff.t()}
          | {:error, :corrupt | :too_large | :unsupported_version}
  def put(part, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:put, part})

  @impl true
  def init(opts) do
    path = Path.join(Keyword.get_lazy(opts, :dir, &Operator.Paths.data_dir/0), @file_name)

    s = %{
      path: path,
      sets: load(path),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      prune_ms: Keyword.get(opts, :prune_ms, @prune_ms)
    }

    {:ok, s |> prune() |> bound(nil) |> save() |> schedule()}
  end

  @impl true
  def handle_call({:put, part}, _from, s) do
    s = prune(s)

    # Another part count under the same id: not this set's part, or the
    # set holds a bad scan. Either way this part starts it over.
    set =
      case Map.get(s.sets, part.id) do
        %{"total" => total} = set when total == part.total -> set
        _none_or_another_count -> %{"total" => part.total, "parts" => %{}}
      end

    parts = Map.put_new(set["parts"], Integer.to_string(part.index), part.data)
    set = set |> Map.put("parts", parts) |> Map.put("seen", s.clock.())
    {reply, s} = add(s, part.id, set)
    {:reply, reply, save(s)}
  end

  @impl true
  def handle_info(:prune, s) do
    before = s.sets
    s = prune(s)
    s = if s.sets == before, do: s, else: save(s)
    {:noreply, schedule(s)}
  end

  defp add(s, id, %{"total" => total, "parts" => parts}) when map_size(parts) == total do
    chunks = for i <- 1..total, do: Map.fetch!(parts, Integer.to_string(i))
    sets = Map.delete(s.sets, id)

    case Handoff.assemble(id, chunks) do
      {:ok, handoff} -> {{:complete, handoff}, %{s | sets: sets}}
      {:error, _} = error -> {error, %{s | sets: sets}}
    end
  end

  defp add(s, id, set) do
    s = bound(%{s | sets: Map.put(s.sets, id, set)}, id)
    {{:partial, map_size(set["parts"]), set["total"]}, s}
  end

  # ── limits ──

  defp prune(s) do
    now = s.clock.()
    %{s | sets: Map.filter(s.sets, fn {_id, set} -> now - set["seen"] <= @expire_ms end)}
  end

  # Drops the sets least recently joined, never `keep`, until within the limits.
  defp bound(s, keep) do
    over? = map_size(s.sets) > @max_sets or bytes(s.sets) > s.max_bytes
    others = Map.delete(s.sets, keep)

    if over? and others != %{} do
      {oldest, _set} = Enum.min_by(others, fn {id, set} -> {set["seen"], id} end)
      bound(%{s | sets: Map.delete(s.sets, oldest)}, keep)
    else
      s
    end
  end

  defp bytes(sets) do
    for {_id, set} <- sets, {_i, data} <- set["parts"], reduce: 0 do
      acc -> acc + byte_size(data)
    end
  end

  defp schedule(s) do
    Process.send_after(self(), :prune, s.prune_ms)
    s
  end

  # ── the file ──

  # Written whole, through a temporary file, so a kill mid-write leaves the
  # previous version.
  defp save(%{sets: sets} = s) when map_size(sets) == 0 do
    _ = File.rm(s.path)
    s
  end

  defp save(s) do
    tmp = s.path <> ".tmp"
    File.mkdir_p!(Path.dirname(s.path))
    File.write!(tmp, Jason.encode!(s.sets))
    File.rename!(tmp, s.path)
    s
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
