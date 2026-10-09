defmodule Operator.Core.Tools.EvalTest do
  use ExUnit.Case, async: false

  alias Operator.Core.EvalKernel
  alias Operator.Core.ToolRegistry
  alias Operator.Core.Tools.Eval
  alias Operator.Core.Tools.Notes
  alias Operator.Test.Dyn, as: T

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!(EvalKernel)
    start_supervised!({ToolRegistry, tools: [Notes, Eval]})
    # No sign-in secrets unless a test gives some.
    Application.put_env(:operator, :eval_secrets, fn -> [] end)
    on_exit(fn -> Application.delete_env(:operator, :eval_secrets) end)
    %{ctx: %{session_id: "s1", call_id: "c1", data_dir: dir}}
  end

  defp eval(code, ctx, extra \\ %{}), do: Eval.run(Map.put(extra, "code", code), ctx)

  test "bindings, aliases and helpers stick within a session until reset", %{ctx: ctx} do
    assert {:ok, "2"} = eval("x = 1 + 1", ctx)

    assert {:ok, "20"} =
             eval("alias Enum, as: E\ndouble = fn n -> n * 2 end\ndouble.(x) * 5", ctx)

    assert {:ok, "6"} = eval("E.sum([x, double.(x)])", ctx)

    # Another session doesn't see them.
    assert {:error, other} = eval("x", %{ctx | session_id: "s2"})
    assert other =~ "undefined variable \"x\""

    # A failed call keeps what the session had.
    assert {:error, _} = eval("x = 5; raise \"no\"", ctx)
    assert {:ok, "2"} = eval("x", ctx)

    assert {:ok, "Bindings cleared (2 names)."} = eval("", ctx, %{"reset" => true})
    assert {:error, gone} = eval("x", ctx)
    assert gone =~ "undefined variable \"x\""
    assert {:ok, "7"} = eval("y = 7", ctx, %{"reset" => true})
    assert {:error, "`code` is empty"} = eval("  ", ctx)
  end

  test "captures what the code prints, from it and from processes it starts", %{ctx: ctx} do
    code = """
    IO.puts("hello")
    IO.write(:stdio, "no newline ")
    Task.await(Task.async(fn -> IO.inspect(:from_task) end))
    :done
    """

    assert {:ok, "stdout:\nhello\nno newline :from_task\nresult:\n:done"} = eval(code, ctx)
    assert {:ok, ":eof"} = eval("IO.gets(\"? \")", ctx)
  end

  test "exceptions, throws, exits and compile errors come back readable", %{ctx: ctx} do
    assert {:error, raised} = eval(~s|IO.puts("before")\nraise ArgumentError, "bad"|, ctx)
    assert raised =~ ~r/\Astdout:\nbefore\nerror:\n\*\* \(ArgumentError\) bad\n    eval:2/
    refute raised =~ "erl_eval"

    assert {:error, inner} = eval(~s|Enum.map([1], fn _ -> raise "inner" end)|, ctx)
    assert inner =~ "** (RuntimeError) inner" and inner =~ "lib/enum.ex"

    assert {:error, "** (throw) :ball" <> _} = eval("throw(:ball)", ctx)
    assert {:error, "** (exit) :gone" <> _} = eval("exit(:gone)", ctx)

    assert {:error, syntax} = eval("x = (", ctx)
    assert syntax =~ "TokenMissingError"

    assert {:error, compile} = eval("nope_not_a_function(1)", ctx)
    assert compile =~ "eval:1:1: undefined function nope_not_a_function/1"
    refute compile =~ "errors have been logged"

    assert {:error, killed} = eval("Process.exit(self(), :kill)", ctx)
    assert killed =~ "was killed"
  end

  test "a timeout kills the evaluation and what it started", %{ctx: ctx} do
    Process.register(self(), :eval_test_parent)

    code = """
    send(:eval_test_parent, {:evaluator, self()})
    IO.puts("started")
    Process.sleep(:infinity)
    """

    assert {:error, text} = eval(code, ctx, %{"timeout_ms" => 100})
    assert text == "stdout:\nstarted\nerror:\nEvaluation timed out after 100 ms and was killed."
    assert_received {:evaluator, pid}
    refute Process.alive?(pid)
  end

  test "the evaluation dies with the tool call that runs it", %{ctx: ctx} do
    Process.register(self(), :eval_test_parent)
    code = "send(:eval_test_parent, {:evaluator, self()}); Process.sleep(:infinity)"
    caller = spawn(fn -> eval(code, ctx) end)

    assert_receive {:evaluator, pid}
    ref = Process.monitor(pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "stopping the run kills the evaluation", %{ctx: ctx} do
    Process.register(self(), :eval_test_parent)
    code = "send(:eval_test_parent, {:evaluator, self()}); Process.sleep(:infinity)"
    caller = spawn(fn -> send(:eval_test_parent, {:result, eval(code, ctx)}) end)

    assert_receive {:evaluator, pid}
    send(caller, {:operator_core_stop, self()})
    assert_receive {:result, {:error, "Stopped by the user."}}
    refute Process.alive?(pid)
  end

  test "a session's evaluations run one at a time and see each other's bindings", %{ctx: ctx} do
    slow = Task.async(fn -> eval("a = 1; Process.sleep(200); a", ctx) end)
    Process.sleep(20)
    fast = Task.async(fn -> eval("b = 2", ctx) end)

    assert {:ok, "1"} = Task.await(slow)
    assert {:ok, "2"} = Task.await(fast)
    assert {:ok, "{1, 2}"} = eval("{a, b}", ctx)
  end

  test "tool.() runs another tool with the call's context, never eval", %{ctx: ctx} do
    assert {:ok, ~s|{:ok, "Appended. Notes now have 1 lines."}|} =
             eval(~s|tool.("notes", %{action: "append", text: "from eval"})|, ctx)

    assert File.read!(Path.join(ctx.data_dir, "notes.md")) == "from eval\n"
    assert {:ok, ~s|{:ok, "from eval\\n"}|} = eval(~s|tool.("notes", %{"action" => "read"})|, ctx)

    assert {:ok, ~s|{:error, "eval cannot call eval"}|} =
             eval(~s|tool.("eval", %{"code" => "1"})|, ctx)

    assert {:ok, ~s|{:error, "no tool named \\"nope\\""}|} = eval(~s|tool.("nope", %{})|, ctx)

    # Rebinding `tool` doesn't stick: the next call gets the helper back.
    assert {:ok, "1"} = eval("tool = 1", ctx)
    assert {:ok, "true"} = eval("is_function(tool, 2)", ctx)
  end

  test "tool.() can't reach a tool the session withholds", %{ctx: ctx} do
    ctx = Map.put(ctx, :withheld, ["notes"])

    assert {:ok, ~s|{:error, "`notes` isn't available in this session"}|} =
             eval(~s|tool.("notes", %{"action" => "read"})|, ctx)
  end

  test "sign-in secrets are redacted from the value and the printed output", %{ctx: ctx} do
    token = "sk-ant-oat01-abcdefghijklmnop"
    Application.put_env(:operator, :eval_secrets, fn -> [token, "short", nil] end)

    assert {:ok, text} = eval(~s|IO.puts("got #{token}"); {"#{token}", "short"}|, ctx)
    refute text =~ token

    assert text ==
             ~s|stdout:\ngot [redacted sign-in token]\nresult:\n{"[redacted sign-in token]", "short"}|

    assert {:error, error} = eval(~s|raise "#{token}"|, ctx)
    assert error =~ "** (RuntimeError) [redacted sign-in token]"

    # A source that fails hides nothing and breaks nothing.
    Application.put_env(:operator, :eval_secrets, fn -> raise "store down" end)
    assert {:ok, ~s|"#{token}"|} == eval(~s|"#{token}"|, ctx)
  end

  test "the live secrets are the stored sign-in tokens, in Operator.Auth's shape" do
    access = "sk-ant-oat01-live-access-0123456789"
    refresh = "sk-ant-ort01-live-refresh-0123456789"
    on_exit(fn -> Operator.SecureStore.delete("auth:anthropic") end)
    unless Process.whereis(Operator.Auth), do: start_supervised!(Operator.Auth)

    :ok =
      Operator.Auth.put(:anthropic, %{
        "type" => "oauth",
        "access" => access,
        "refresh" => refresh,
        "expires" => System.os_time(:millisecond) + 3_600_000
      })

    secrets = EvalKernel.live_secrets()
    assert access in secrets
    assert refresh in secrets
  end

  test "output is capped: a huge value, a flood of prints", %{ctx: ctx} do
    assert {:ok, value} = eval(~s|String.duplicate("a", 100_000)|, ctx)
    assert byte_size(value) < 9_000
    assert value =~ "..."

    assert {:ok, list} = eval("Enum.to_list(1..100_000)", ctx)
    assert list =~ "..."
    assert byte_size(list) < 9_000

    assert {:ok, printed} = eval(~s|for _ <- 1..10_000, do: IO.puts("line"); :ok|, ctx)
    assert printed =~ ~r/\(\d+ more bytes printed, not kept\)\nresult:\n:ok\z/
    assert byte_size(printed) < 7_000
  end

  test "bindings too big to keep are dropped, the call still answers", %{ctx: ctx} do
    assert {:ok, "1"} = eval("small = 1", ctx)
    assert {:ok, text} = eval("big = Enum.to_list(1..1_000_000); length(big)", ctx)
    assert text =~ "were not kept" and text =~ "1000000"
    assert {:ok, "1"} = eval("small", ctx)
    assert {:error, _} = eval("big", ctx)

    # Binaries count, though they live off the process heap.
    assert {:ok, text} = eval(~s|blob = :binary.copy("a", 10_000_000); byte_size(blob)|, ctx)
    assert text =~ "the bindings came to 10.0 MB, over the 4.0 MB" and text =~ "10000000"
    assert {:error, _} = eval("blob", ctx)
  end

  test "memory past the cap kills the evaluation, binaries included", %{ctx: ctx} do
    code = ~s|Enum.reduce(1..100, [], fn _, acc -> [:binary.copy("a", 1_000_000) \| acc] end)|
    empty = %{binding: [], env: nil}

    assert {:error, text, nil} =
             EvalKernel.evaluate(code, empty, ctx, 10_000, max_heap_bytes: 20_000_000)

    assert text ==
             "The evaluation process was killed (its memory passed 20.0 MB, or the code killed it)."
  end

  test "sessions are bounded: the least recently used goes first" do
    stop_supervised!(EvalKernel)
    start_supervised!({EvalKernel, max_sessions: 2})
    session = %{binding: [a: 1], env: nil}

    :ok = EvalKernel.put("a", session)
    :ok = EvalKernel.put("b", session)
    _ = EvalKernel.get("a")
    :ok = EvalKernel.put("c", session)

    assert Enum.sort(EvalKernel.sessions()) == ["a", "c"]
  end

  test "idle sessions are swept" do
    stop_supervised!(EvalKernel)
    start_supervised!({EvalKernel, idle_ms: 0, sweep_ms: 10})
    :ok = EvalKernel.put("a", %{binding: [a: 1], env: nil})
    Process.sleep(50)
    assert EvalKernel.sessions() == []
  end

  test "rejects a bad timeout and passes its selftest", %{ctx: ctx} do
    assert {:error, "timeout_ms must be" <> _} = eval("1", ctx, %{"timeout_ms" => "soon"})
    assert Eval.selftest() == :ok
  end

  @tag :capture_log
  test "Dyn modules by their logical names resolve to the running generation", %{
    ctx: ctx,
    tmp_dir: dir
  } do
    T.purge_all()
    on_exit(&T.purge_all/0)
    T.start_keeper(Path.join(dir, "dyn"))

    n =
      T.activate!(%{
        "menu.ex" => "defmodule Operator.Dyn.Menu do\n  def items, do: [:a]\nend\n",
        "showcase/phone/sms.ex" =>
          "defmodule Operator.Dyn.Showcase.Phone.Sms do\n  def hi, do: :hi\nend\n"
      })

    assert {:ok, "[:a]"} = eval("Operator.Dyn.Menu.items()", ctx)
    assert {:ok, ":hi"} = eval("alias Operator.Dyn.Showcase.Phone\nPhone.Sms.hi()", ctx)
    assert {:ok, "Operator.Dyn.G#{n}.Menu"} == eval("Elixir.Operator.Dyn.Menu", ctx)

    # Not in the generation: the usual error.
    assert {:error, nope} = eval("Operator.Dyn.Nope.x()", ctx)
    assert nope =~ "Operator.Dyn.Nope"
  end
end
