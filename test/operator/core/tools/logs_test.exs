defmodule Operator.Core.Tools.LogsTest do
  use ExUnit.Case, async: false

  require Logger

  alias Operator.Core.LogRing
  alias Operator.Core.Tools.Logs

  @moduletag :capture_log

  setup do
    start_supervised!({LogRing, max: 5})
    :ok
  end

  # One string per event (a crash report spans lines).
  defp lines({:ok, text}), do: String.split(text, ~r/\n(?=\d\d:\d\d:\d\d\.\d{3} \[)/)

  test "Logger output lands in the ring as timestamped lines, newest last" do
    Logger.info("first thing")
    Logger.error("second thing")

    assert [a, b] = lines(Logs.run(%{"grep" => "thing"}, %{}))
    assert a =~ ~r/\A\d\d:\d\d:\d\d\.\d{3} \[info\] first thing/
    assert b =~ ~r/\A\d\d:\d\d:\d\d\.\d{3} \[error\] second thing/
  end

  test "filters by minimum level, grep (regex or substring) and limit" do
    Logger.debug("d one")
    Logger.info("i two")
    Logger.warning("w three [x]")
    Logger.error("e four")

    assert [_, _, _, _] = lines(Logs.run(%{"level" => "debug"}, %{}))
    assert [_, _, _] = lines(Logs.run(%{}, %{}))
    assert [w, e] = lines(Logs.run(%{"level" => "warning"}, %{}))
    assert w =~ "[warning] w three" and e =~ "[error] e four"

    assert [i] = lines(Logs.run(%{"grep" => "I T.O"}, %{}))
    assert i =~ "i two"
    # Not a valid regex: matched as text.
    assert [w] = lines(Logs.run(%{"grep" => "three [x"}, %{}))
    assert w =~ "w three"

    assert [e] = lines(Logs.run(%{"limit" => 1}, %{}))
    assert e =~ "e four"

    assert {:ok, "(no log lines match)"} = Logs.run(%{"grep" => "zebra"}, %{})
    assert {:error, "level must be" <> _} = Logs.run(%{"level" => "loud"}, %{})
    assert {:error, "limit must be" <> _} = Logs.run(%{"limit" => 0}, %{})
  end

  # Events with metadata Logger isn't configured for go straight to the
  # handler, as `:logger` would hand them over.
  defp handle(level, text, meta) do
    LogRing.log(%{level: level, msg: {:string, text}, meta: meta}, %{
      config: %{table: LogRing, max: 5}
    })
  end

  test "since_seconds keeps only recent lines" do
    handle(:info, "old line", %{time: :os.system_time(:microsecond) - 120_000_000})
    Logger.info("new line")

    assert [new] = lines(Logs.run(%{"since_seconds" => 60}, %{}))
    assert new =~ "new line"
    assert [_, _] = lines(Logs.run(%{"since_seconds" => 600}, %{}))
  end

  test "the ring keeps only the last max events" do
    for n <- 1..12, do: Logger.info("event #{n}")

    assert entries = lines(Logs.run(%{"grep" => "event", "limit" => 500}, %{}))
    assert Enum.map(entries, &(&1 |> String.split(" ") |> List.last())) == ~w(8 9 10 11 12)
    assert :ets.info(LogRing, :size) == 6
  end

  test "a crash says why, once" do
    handle(:error, "plugin failed", %{crash_reason: {%RuntimeError{message: "kaput"}, []}})

    {:ok, pid} = Task.start(fn -> raise "screen boom" end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    Logger.flush()

    assert [plugin, task] = lines(Logs.run(%{"level" => "error"}, %{}))
    assert plugin =~ "[error] plugin failed (crash: ** (RuntimeError) kaput)"
    assert task =~ "** (RuntimeError) screen boom"
    refute task =~ "crash: "
  end

  test "lines are capped" do
    Logger.info(String.duplicate("x", 10_000))
    assert [line] = lines(Logs.run(%{}, %{}))
    assert byte_size(line) <= 1_600
  end

  test "says so when the ring isn't running, and passes its selftest" do
    stop_supervised!(LogRing)
    assert {:error, "the log ring isn't running" <> _} = Logs.run(%{}, %{})
    Logger.info("no ring, no crash")
    assert Logs.selftest() == :ok
  end
end
