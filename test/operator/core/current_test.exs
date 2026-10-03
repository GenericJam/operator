defmodule Operator.Core.CurrentTest do
  use ExUnit.Case, async: true

  import Operator.Test.LoopHelpers, only: [collect: 0]
  import Operator.Test.ObserverHelpers

  alias Operator.Core.Current
  alias Operator.Core.Loop

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fixture Path.expand("../../fixtures/omp_session.jsonl", __DIR__)

  test "opens an omp session from elsewhere: copied in, continued on an OpenRouter model",
       %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    elsewhere = Path.join(dir, "from_omp.jsonl")
    File.cp!(@fixture, elsewhere)
    original = File.read!(elsewhere)

    %{current: current} = start_current(sessions, [[{:text, "hi from the phone"}]])
    assert {:ok, loop} = Current.open(elsewhere, current)
    assert Current.current(current) == loop

    snap = Loop.snapshot(loop)
    # omp ran it on anthropic:claude-opus-5-5, which Operator can't call
    assert snap.model == Operator.Core.default_model()
    assert Enum.count(snap.entries) == 78

    :ok = Loop.subscribe(loop)
    :ok = Loop.prompt(loop, "carry on")
    assert %{reason: :done} = List.last(collect())

    copy = Path.join(sessions, "from_omp.jsonl")
    assert String.starts_with?(File.read!(copy), original)
    assert File.read!(copy) =~ "carry on"
    assert File.read!(elsewhere) == original

    assert {:error, :enoent} = Current.open(Path.join(dir, "missing.jsonl"), current)
    assert Current.current(current) == loop
  end
end
