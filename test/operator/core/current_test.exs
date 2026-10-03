defmodule Operator.Core.CurrentTest do
  # async: false: the sign-ins (Operator.Auth) are app-wide.
  use ExUnit.Case, async: false

  import Operator.Test.LoopHelpers, only: [collect: 0]
  import Operator.Test.ObserverHelpers

  alias Operator.Auth
  alias Operator.Core.Current
  alias Operator.Core.Loop

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fixture Path.expand("../../fixtures/omp_session.jsonl", __DIR__)

  setup %{tmp_dir: dir} do
    start_supervised!(Auth)
    on_exit(fn -> Operator.SecureStore.delete("auth:anthropic") end)

    elsewhere = Path.join(dir, "from_omp.jsonl")
    File.cp!(@fixture, elsewhere)
    %{sessions: Path.join(dir, "sessions"), elsewhere: elsewhere}
  end

  test "opens an omp session from elsewhere: copied in; signed out of its provider, on the default model",
       %{tmp_dir: dir, sessions: sessions, elsewhere: elsewhere} do
    original = File.read!(elsewhere)

    %{current: current} = start_current(sessions, [[{:text, "hi from the phone"}]])
    assert {:ok, loop} = Current.open(elsewhere, current)
    assert Current.current(current) == loop

    snap = Loop.snapshot(loop)
    # omp ran it on anthropic:claude-opus-5-5, and the phone isn't signed in to Anthropic
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

  test "signed in to its provider, an omp session continues on its own model",
       %{sessions: sessions, elsewhere: elsewhere} do
    creds = %{
      "type" => "oauth",
      "access" => "at",
      "refresh" => "rt",
      "expires" => System.os_time(:millisecond) + 3_600_000
    }

    :ok = Auth.put(:anthropic, creds)

    %{current: current} = start_current(sessions, [])
    assert {:ok, loop} = Current.open(elsewhere, current)
    assert Loop.snapshot(loop).model == "anthropic:claude-opus-5-5"
  end
end
