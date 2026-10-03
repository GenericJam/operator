defmodule Mix.Tasks.Operator.HandoffTest do
  # async: false: Mix.shell/1 and the environment are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Operator.Handoff, as: HandoffTask
  alias Operator.Handoff

  @moduletag :tmp_dir

  @with_handoff Path.expand("../../fixtures/omp_handoff_session.jsonl", __DIR__)
  @without_handoff Path.expand("../../fixtures/omp_session.jsonl", __DIR__)

  setup %{tmp_dir: tmp} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    System.put_env("PI_CODING_AGENT_DIR", Path.join(tmp, "agent"))

    on_exit(fn ->
      Mix.shell(shell)
      System.delete_env("PI_CODING_AGENT_DIR")
    end)

    cwd = Path.join(tmp, "project")
    File.mkdir_p!(cwd)
    dir = HandoffTask.sessions_dir(cwd)
    File.mkdir_p!(dir)
    %{cwd: cwd, dir: dir}
  end

  # Two sessions for the directory: `newest` written last.
  defp sessions(dir, oldest, newest) do
    old = Path.join(dir, "2026-10-01T09-00-00-000Z_01a10000-old.jsonl")
    new = Path.join(dir, "2026-10-03T09-00-00-000Z_01a10000-new.jsonl")
    File.cp!(oldest, old)
    File.cp!(newest, new)
    File.touch!(old, 1_790_000_000)
    File.touch!(new, 1_790_000_100)
    new
  end

  # Runs the task, pressing Enter at every prompt. Without EQRCode (a :dev
  # dependency) each code is printed as text. Returns those links and the
  # prompts shown.
  defp run_task(args) do
    for _ <- 1..10, do: send(self(), {:mix_shell_input, :prompt, "\n"})
    capture_io(fn -> HandoffTask.run(args) end)
    links = :info |> shell() |> Enum.flat_map(&Regex.scan(~r/operator:\/\/handoff\S+/, &1))
    {List.flatten(links), shell(:prompt)}
  end

  defp shell(kind) do
    receive do
      {:mix_shell, ^kind, [text]} -> [text | shell(kind)]
    after
      0 -> []
    end
  end

  test "omp's directory names: relative to home, to the temp dir, or the whole path" do
    opts = [root: "/sessions", home: "/Users/k", tmp: "/var/tmp-k"]

    assert HandoffTask.sessions_dir("/Users/k/code/operator", opts) == "/sessions/-code-operator"
    assert HandoffTask.sessions_dir("/Users/k", opts) == "/sessions/-"
    assert HandoffTask.sessions_dir("/var/tmp-k/build/x", opts) == "/sessions/-tmp-build-x"
    assert HandoffTask.sessions_dir("/var/tmp-k", opts) == "/sessions/-tmp"
    assert HandoffTask.sessions_dir("/opt/src/app", opts) == "/sessions/--opt-src-app--"
  end

  test "symlinks are resolved before naming, as omp does", %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    File.mkdir_p!(Path.join(home, "code/app"))
    File.ln_s!(home, Path.join(tmp, "alias"))

    assert HandoffTask.sessions_dir(Path.join(tmp, "alias/code/app"), root: "/s", home: home) ==
             "/s/-code-app"
  end

  test "the newest session's latest handoff, one code per Enter", %{cwd: cwd, dir: dir} do
    sessions(dir, @without_handoff, @with_handoff)

    # One code, one Enter: then the task is done.
    assert {[link], [_prompt]} = run_task(["--cwd", cwd])

    {:ok, part} = Handoff.parse(link)

    assert Handoff.assemble(part.id, [part.data]) ==
             {:ok,
              %{
                title: "Ship the QR handoff",
                cwd: "/Users/kevin/code/operator",
                summary:
                  "## Goal\nCarry omp's handoff to the phone in QR codes.\n\n## Next\n- Run the device check: cold and warm.",
                created: DateTime.to_unix(~U[2026-10-03 10:15:00.000Z], :millisecond)
              }}
  end

  test "a long handoff is shown over several codes, in order", %{tmp_dir: tmp} do
    summary = Base.encode64(:crypto.strong_rand_bytes(3_000))

    entry =
      Jason.encode!(%{
        "type" => "compaction",
        "id" => "b0000001",
        "timestamp" => "2026-10-03T11:00:00.000Z",
        "summary" => summary,
        "method" => "handoff"
      })

    path = Path.join(tmp, "long.jsonl")
    File.write!(path, File.read!(@with_handoff) <> entry <> "\n")

    {links, prompts} = run_task([path])
    total = length(links)
    assert total > 1
    assert length(prompts) == total

    parts = for link <- links, do: elem(Handoff.parse(link), 1)
    assert Enum.map(parts, & &1.index) == Enum.to_list(1..total)

    assert {:ok, %{summary: ^summary}} =
             Handoff.assemble(hd(parts).id, Enum.map(parts, & &1.data))
  end

  test "no handoff in the newest session: run /handoff in omp first", %{cwd: cwd, dir: dir} do
    newest = sessions(dir, @with_handoff, @without_handoff)

    error = assert_raise Mix.Error, fn -> run_task(["--cwd", cwd]) end
    assert error.message == "No handoff in #{newest}: run /handoff in omp first."
  end

  test "no omp session for the directory, or a bad argument, is said plainly", %{tmp_dir: tmp} do
    elsewhere = Path.join(tmp, "elsewhere")
    File.mkdir_p!(elsewhere)

    assert_raise Mix.Error, ~r/No omp session for #{Regex.escape(elsewhere)}/, fn ->
      run_task(["--cwd", elsewhere])
    end

    assert_raise Mix.Error, ~r/Usage/, fn -> run_task(["a.jsonl", "b.jsonl"]) end
  end
end
