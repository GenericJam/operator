defmodule Operator.Core.Tools.DynPropose do
  @moduledoc """
  Core tool: turn the Dyn staging copy into a candidate generation
  (`Operator.Core.Dyn.propose/2`: static check, compile, selftests). It
  never activates anything: the human approves on the phone.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Check
  alias Operator.Core.Tools.DynTool

  @diff_max 12_000

  @impl true
  def name, do: "dyn_propose"

  @impl true
  def description do
    "Propose the staged Dyn sources as a new generation: they are checked, compiled and " <>
      "selftested, and the result (diff, tests, or every error with file:line) comes back. " <>
      "It does NOT activate anything: the human must approve it on the phone with the screen " <>
      "lock (fingerprint, face, PIN, pattern or password)."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "rationale" => %{
          "type" => "string",
          "description" => "One line: what the change does and why (shown to the human)."
        }
      },
      "required" => ["rationale"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 120_000

  @impl true
  def run(args, ctx) do
    keeper = DynTool.keeper(ctx)

    case Dyn.propose(args["rationale"] || "", keeper) do
      {:ok, proposal} -> {:ok, proposed(proposal)}
      {:error, reason} -> {:error, refused(reason, keeper)}
    end
  end

  defp proposed(p) do
    tests =
      Enum.map_join(
        p.selftests,
        "\n",
        &"- #{&1.module} (#{&1.kind}): ok, #{&1.ms} ms: #{&1.detail}"
      )

    warnings =
      if p.warnings == [], do: "", else: "\nCompiler warnings:\n" <> Enum.join(p.warnings, "\n")

    """
    Proposed generation G#{p.n} (on top of G#{p.parent}): #{p.rationale}

    It is NOT active. The human has to approve it on the phone with the screen lock; you can't \
    activate it yourself. Once approved it runs on probation and is reverted automatically if \
    it keeps crashing.

    Compiled in #{p.compile_ms} ms. Selftests:
    #{tests}#{warnings}

    Diff:
    ```diff
    #{cut(p.diff)}```
    """
  end

  defp cut(diff) when byte_size(diff) <= @diff_max, do: diff

  defp cut(diff) do
    String.slice(diff, 0, @diff_max) <>
      "\n… (diff cut, #{byte_size(diff) - @diff_max} more bytes)\n"
  end

  defp refused(:no_changes, keeper),
    do:
      "Nothing to propose: staging is the same as generation G#{Dyn.status(keeper).generation}. " <>
        "Change it with dyn_write or dyn_edit first."

  defp refused(:rationale_required, _keeper), do: "`rationale` is required: one line on why."

  defp refused(:proposal_limit, _keeper),
    do:
      "Too many proposals in this app launch (each one uses memory only a restart frees). " <>
        "Ask the human to restart the app, then propose again."

  defp refused(:not_running, _keeper), do: "The Dyn layer isn't running."

  defp refused(%{stage: :check, violations: violations}, _keeper),
    do: "Rejected by the static check; fix these and propose again:\n" <> Check.format(violations)

  defp refused(%{stage: :compile, n: n, reason: reason}, _keeper),
    do: "Rejected: generation G#{n} doesn't compile:\n" <> reason

  defp refused(%{stage: :selftest, n: n, reason: reason}, _keeper),
    do: "Rejected: generation G#{n} failed its selftests:\n" <> reason

  defp refused(%{stage: stage, reason: reason}, _keeper), do: "Rejected (#{stage}): #{reason}"

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      evil = "defmodule Operator.Dyn.Evil do\n  def x, do: System.halt()\nend\n"

      with :ok <-
             DynTool.expect(
               run(%{"rationale" => "x"}, ctx),
               &match?({:error, "Nothing to propose" <> _}, &1)
             ),
           :ok <- Dyn.stage_put("evil.ex", evil, ctx.dyn),
           :ok <-
             DynTool.expect(
               run(%{"rationale" => " "}, ctx),
               &match?({:error, "`rationale` is required" <> _}, &1)
             ) do
        DynTool.expect(
          run(%{"rationale" => "halt"}, ctx),
          &match?({:error, "Rejected by the static check;" <> _}, &1)
        )
      end
    end)
  end
end
