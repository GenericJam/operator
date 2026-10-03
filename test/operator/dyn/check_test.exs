defmodule Operator.Core.Dyn.CheckTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Dyn.Check
  alias Operator.Test.Dyn

  defp check(body) do
    """
    defmodule Operator.Dyn.Probe do
      def go(pid, mod, fun) do
        _ = {pid, mod, fun}
        #{body}
      end
    end
    """
  end

  # The violations `body` causes, as "line: message" lines.
  defp violation(body) do
    assert {:error, violations} = Check.run(%{"probe.ex" => check(body)})
    Enum.map_join(violations, "\n", &"#{&1.line}: #{&1.message}")
  end

  test "accepts a valid tool and a valid screen" do
    sources = %{
      "weather.ex" => Dyn.tool("Weather", "weather"),
      "notes.ex" => Dyn.screen("Notes", "hi"),
      "helpers/format.ex" => """
      defmodule Operator.Dyn.Helpers.Format do
        alias Operator.Dyn.Notes

        def now, do: System.monotonic_time() |> Integer.to_string()
        def bye(pid), do: Process.exit(self(), {:done, pid})
        def screen, do: Notes
        def up(list), do: Enum.map(list, &String.upcase/1)
        def call, do: apply(String, :upcase, ["a"])
        def setting, do: :persistent_term.get(:operator_dyn_setting, :default)
      end
      """
    }

    assert {:ok, parsed} = Check.run(sources)
    assert Enum.map(parsed, &elem(&1, 0)) == ["helpers/format.ex", "notes.ex", "weather.ex"]
  end

  test "rejects each banned construct, with the line" do
    banned = [
      {":code.purge(mod)", ":code"},
      {":erlang.halt()", ":erlang.halt"},
      {"System.halt()", "System.halt"},
      {"System.stop()", "System.stop"},
      {~s|System.cmd("rm", ["-rf", "/"])|, "System.cmd"},
      {~s|Port.open({:spawn, "sh"}, [])|, "Port"},
      {~s|:os.cmd(~c"ls")|, ":os.cmd"},
      {~s|Code.eval_string("1")|, "Code"},
      {~s|Code.compile_string("x")|, "Code"},
      {"Mob.Dist.ensure_started([])", "Mob.Dist"},
      {"Node.connect(:x@y)", "Node"},
      {":init.stop()", ":init"},
      {~s|File.read("/data")|, "File"},
      {~s|Path.join("a", "b")|, "Path"},
      {"Process.exit(pid, :kill)", "exit/2 may only exit self()"},
      {"pid |> Process.exit(:kill)", "exit/2 may only exit self()"},
      {"apply(mod, :halt, [])", "module held in a variable"},
      {"Kernel.apply(mod, :halt, [])", "module held in a variable"},
      {"apply(System, fun, [])", "computed function"},
      {"mod.halt()", "dynamic dispatch"},
      {"Operator.Core.Loop.stop(pid)", "Operator's own code"},
      {"Operator.Boot.timings()", "Operator's own code"},
      {"Operator.Core.ToolRegistry", "Operator's own code"},
      {":\"Elixir.System\".halt()", "write module names as aliases"},
      {~s|String.to_atom("Elixir.System")|, "String.to_atom"},
      {"&System.halt/0", "System.halt"},
      {"Mob.Test.tap(:x, :y)", "Mob.Test"},
      {":erlang.suspend_process(pid)", ":erlang.suspend_process"},
      {":erlang.resume_process(pid)", ":erlang.resume_process"},
      {":erlang.trace(pid, true, [:call])", ":erlang.trace"},
      {":erlang.trace_pattern({:m, :f, :_}, true)", ":erlang.trace_pattern"},
      {":erlang.trace_delivered(pid)", ":erlang.trace_delivered"},
      {":erlang.system_monitor(pid, [:busy_port])", ":erlang.system_monitor"},
      {":erlang.system_profile(pid, [:runnable_procs])", ":erlang.system_profile"},
      {":seq_trace.set_token(:label, 1)", ":seq_trace"},
      {":dbg.tracer()", ":dbg"},
      {":erts_debug.df(:m)", ":erts_debug"},
      {":erts_internal.purge_module(:m, :prepare)", ":erts_internal"},
      {":observer_backend.sys_info()", ":observer_backend"},
      {":persistent_term.put(:k, 1)", ":persistent_term.put"},
      {":persistent_term.erase(:k)", ":persistent_term.erase"},
      {"Process.list()", "Process.list"},
      {":erlang.processes()", ":erlang.processes"}
    ]

    for {body, expected} <- banned do
      assert violation(body) =~ ~r/^4: .*#{Regex.escape(expected)}/, "#{body} was not rejected"
    end
  end

  test "sees through aliases, imports, delegation and ~MOB templates" do
    for {source, line, expected} <- [
          {"alias System, as: S\n  def go, do: S.halt()", 3, "System.halt"},
          {"alias :code, as: C\n  def go(m), do: C.purge(m)", 2, ":code"},
          {"import System\n  def go, do: :ok", 2, "imports System"},
          {"defdelegate go(), to: System, as: :halt", 2, "System.halt"},
          {"defmacro go, do: :ok", 2, "macro"},
          {"@on_load :go\n  def go, do: :ok", 2, "@on_load"},
          {"def go, do: ~MOB|<Text text={System.halt()} />|", 2, "System.halt"},
          {"defimpl String.Chars, for: Atom do\n    def to_string(_), do: \"\"\n  end", 2,
           "protocol"}
        ] do
      src = "defmodule Operator.Dyn.Probe do\n  #{source}\nend\n"
      assert {:error, violations} = Check.run(%{"p.ex" => src})

      assert Enum.any?(violations, &(&1.line == line and &1.message =~ expected)),
             "#{inspect(source)}: #{inspect(violations)}"
    end
  end

  test "modules must live under Operator.Dyn, and only modules at the top level" do
    assert {:error, [%{line: 1, message: m1}]} =
             Check.run(%{"a.ex" => "defmodule Operator.Core.Evil do\nend\n"})

    assert m1 =~ "Operator.Dyn.*"

    assert {:error, [%{message: m2}]} =
             Check.run(%{"b.ex" => "defmodule Operator.Dyn.G7.Foo do\nend\n"})

    assert m2 =~ "reserved"

    assert {:error, [%{line: 1, message: m3}]} = Check.run(%{"c.ex" => "IO.puts(:hi)\n"})
    assert m3 =~ "top level"
  end

  test "reports every violation of every file, and syntax errors" do
    sources = %{
      "a.ex" =>
        "defmodule Operator.Dyn.A do\n  def x, do: File.rm(\"/\")\n  def y, do: :init.stop()\nend\n",
      "b.ex" => "defmodule Operator.Dyn.B do\n  def x(, do: 1\nend\n"
    }

    assert {:error, violations} = Check.run(sources)

    assert [{"a.ex", 2}, {"a.ex", 3}, {"b.ex", 2}] =
             Enum.map(violations, &{&1.file, &1.line})

    assert Check.format(violations) =~ "a.ex:2: calls File.rm/1"
  end
end
