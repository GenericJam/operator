defmodule Operator.Core.LogRing do
  @moduledoc """
  The last 1,000 `Logger` events on the phone, kept in memory so the agent
  can read what its screens, tools and plugins logged (the `logs` tool,
  `Operator.Core.Tools.Logs`). On the phone mob's `Mob.NativeLogger` sends
  the same events to logcat, which only a Mac on adb can read; this is the
  copy the app itself can.

  It is an OTP `:logger` handler next to the others: `log/2` runs in the
  process that logged, formats the event into one capped string at once (so
  no term the event carried is kept alive) and writes it into a public ETS
  table this process owns, with no message to it. The table is an
  ordered set keyed by a counter, and each write deletes the entry `max`
  writes back, so it never holds more than `max` lines of at most
  1,500 bytes. In memory only: it is gone on a restart. Started first
  thing in `Operator.App.on_start/0`, so boot errors are in it.

  The handler never raises (`:logger` removes a handler that does) and
  this module never logs.
  """
  use GenServer

  @handler_id :operator_log_ring
  @default_max 1_000
  @max_line_bytes 1_500
  @seq :seq

  @type entry :: %{
          time: integer(),
          level: Logger.level(),
          line: String.t()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts the table's owner and installs the handler. Options: `:max` (lines
  kept, default #{@default_max}), `:name` (the table and process name, default
  this module; tests use their own), `:handler_id`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  The kept lines, oldest first, filtered: `:level` (the minimum, default
  `:debug`), `:grep` (a case-insensitive regex, or a substring when it isn't
  one), `:since_us` (system time in microseconds), `:limit` (the newest N).
  `{:error, :not_running}` when the ring isn't installed.
  """
  @spec recent(keyword(), atom()) :: {:ok, [entry()]} | {:error, :not_running}
  def recent(opts \\ [], table \\ __MODULE__) do
    rows = :ets.select(table, [{{:"$1", :_, :_, :_}, [{:is_integer, :"$1"}], [:"$_"]}])
    level = Keyword.get(opts, :level, :debug)
    since = Keyword.get(opts, :since_us)
    match = matcher(Keyword.get(opts, :grep))

    entries =
      for {_n, time, lvl, line} <- rows,
          :logger.compare_levels(lvl, level) != :lt,
          since == nil or time >= since,
          match.(line),
          do: %{time: time, level: lvl, line: line}

    {:ok, take_last(entries, Keyword.get(opts, :limit))}
  rescue
    ArgumentError -> {:error, :not_running}
  end

  defp take_last(entries, nil), do: entries
  defp take_last(entries, n), do: Enum.take(entries, -n)

  defp matcher(nil), do: fn _ -> true end
  defp matcher(""), do: fn _ -> true end

  defp matcher(grep) do
    case Regex.compile(grep, "iu") do
      {:ok, re} ->
        &Regex.match?(re, &1)

      {:error, _} ->
        needle = String.downcase(grep)
        &String.contains?(String.downcase(&1), needle)
    end
  end

  # ── GenServer ──

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    handler_id = Keyword.get(opts, :handler_id, @handler_id)
    max = Keyword.get(opts, :max, @default_max)

    new_table(name)
    Process.flag(:trap_exit, true)

    # A handler left by an earlier owner wrote to a table that died with it.
    _ = :logger.remove_handler(handler_id)

    :ok =
      :logger.add_handler(handler_id, __MODULE__, %{
        level: :all,
        config: %{table: name, max: max}
      })

    {:ok, handler_id}
  end

  @doc false
  # The table alone, for a ring fed by calling `log/2` directly (selftests).
  @spec new_table(atom()) :: atom()
  def new_table(name) do
    :ets.new(name, [:ordered_set, :public, :named_table, write_concurrency: true])
    :ets.insert(name, {@seq, 0})
    name
  end

  @impl true
  def terminate(_reason, handler_id) do
    _ = :logger.remove_handler(handler_id)
    :ok
  end

  # ── :logger handler ──

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level} = event, %{config: %{table: table, max: max}}) do
    time = event.meta[:time] || :os.system_time(:microsecond)
    n = :ets.update_counter(table, @seq, 1)
    :ets.insert(table, {n, time, level, format(event, time)})
    :ets.delete(table, n - max)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def log(_event, _config), do: :ok

  @doc """
  One event as `HH:MM:SS.mmm [level] message`, with ` (crash: reason)` when
  the event carries one its message doesn't show; capped. A message may
  span lines (a crash report's stacktrace does).
  """
  @spec format(:logger.log_event(), integer()) :: String.t()
  def format(%{level: level, meta: meta} = event, time) do
    text = event |> Logger.Formatter.format_event(@max_line_bytes) |> IO.iodata_to_binary()

    line =
      case crash(meta[:crash_reason], text) do
        nil -> [clock(time), " [", Atom.to_string(level), "] ", text]
        crash -> [clock(time), " [", Atom.to_string(level), "] ", text, " (crash: ", crash, ")"]
      end
      |> IO.iodata_to_binary()

    if byte_size(line) > @max_line_bytes,
      do: IO.iodata_to_binary(Logger.Formatter.truncate(line, @max_line_bytes)),
      else: line
  end

  defp clock(time_us) do
    {_date, {h, m, s}} = :calendar.system_time_to_local_time(time_us, :microsecond)
    ms = time_us |> div(1000) |> rem(1000)
    :io_lib.format(~c"~2..0w:~2..0w:~2..0w.~3..0w", [h, m, s, ms])
  end

  # The crash reason, unless the message already says it (OTP's crash
  # reports, translated by Logger, do).
  defp crash({%{__exception__: true} = e, stack}, text) when is_list(stack) do
    banner = Exception.format_banner(:error, e, stack)
    if String.contains?(text, banner), do: nil, else: banner
  end

  defp crash({reason, stack}, text) when is_list(stack) do
    banner = Exception.format_exit(reason)
    if String.contains?(text, banner), do: nil, else: banner
  end

  defp crash(_, _), do: nil
end
