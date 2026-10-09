defmodule Operator.Core.Tools.Eval do
  @moduledoc """
  Core tool: evaluates Elixir on the phone's own BEAM, like an iex prompt
  that keeps its bindings between calls of a session. It is how the agent
  looks at itself (processes, ETS, application env, its own state), probes
  an API before writing a screen against it, and uses its other tools
  from code (`tool.("notes", %{"action" => "read"})`).

  `Operator.Core.EvalKernel` does the work: a fresh process per call with
  its output captured and a timeout and heap cap, and a bounded store of
  each session's bindings.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.EvalKernel

  @default_timeout_ms 30_000
  @max_timeout_ms 120_000

  @impl true
  def name, do: "eval"

  @impl true
  def description do
    """
    Evaluate Elixir code on this phone's BEAM and get back the inspected value of the \
    last expression, with anything it printed (IO.puts/IO.inspect). Bindings are sticky \
    within this session: a variable (or anonymous-function helper) bound in one call is \
    there in the next, and so are alias/import/require; reset: true clears them first. \
    `tool` is pre-bound: tool.("name", %{"arg" => value}) runs any other agent tool with \
    this call's context and returns its {:ok, _} | {:error, _} (not eval itself, nor a \
    tool this session doesn't offer you). A session's evals run one at a time. Dyn modules \
    by their logical names (`Operator.Dyn.Menu`) resolve to the running generation.

    This has full authority over the app's BEAM: use it to inspect processes \
    (Process.info, :sys.get_state), ETS tables, Application.get_env, read the agent's own \
    state and files, and call a plugin's API to see what it really returns before building \
    a screen on it. Code runs in a throwaway process, killed at timeout_ms; but what it \
    does to other processes is real: killing or crashing processes it doesn't own, or \
    calling GenServers that block, can break the app until it restarts. Output is \
    truncated (inspect limits, about 8 KB of value and 6 KB of printed text); sign-in \
    tokens in it are replaced by [redacted sign-in token].
    """
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" => "Elixir source; the value of the last expression is returned."
        },
        "reset" => %{
          "type" => "boolean",
          "description" => "Clear this session's bindings before evaluating (code may be empty)."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_timeout_ms,
          "description" =>
            "Kill the evaluation after this long (default #{@default_timeout_ms}, max #{@max_timeout_ms})."
        }
      },
      "required" => ["code"],
      "additionalProperties" => false
    }
  end

  # Over the longest evaluation, so the evaluation's own timeout (with its
  # printed output) answers first.
  @impl true
  def timeout_ms, do: @max_timeout_ms + 5_000

  @impl true
  def run(args, ctx) do
    id = Map.get(ctx, :session_id)

    with {:ok, timeout} <- timeout(args["timeout_ms"]),
         {:ok, code} <- code(args["code"]) do
      # The loop runs a turn's calls side by side: one evaluation per
      # session at a time, so none starts from bindings another is changing.
      EvalKernel.locked(id, fn ->
        reset_and_evaluate(code, args["reset"] == true, id, ctx, timeout)
      end)
    end
  end

  defp reset_and_evaluate(code, reset?, id, ctx, timeout) do
    cleared = if reset?, do: EvalKernel.reset(id)
    evaluate(code, cleared, id, ctx, timeout)
  end

  defp evaluate("", nil, _id, _ctx, _timeout), do: {:error, "`code` is empty"}

  defp evaluate("", cleared, _id, _ctx, _timeout),
    do: {:ok, "Bindings cleared (#{cleared} names)."}

  defp evaluate(code, _cleared, id, ctx, timeout) do
    case EvalKernel.evaluate(code, EvalKernel.get(id), ctx, timeout) do
      {:ok, text, nil} ->
        {:ok, text}

      {:ok, text, session} ->
        :ok = EvalKernel.put(id, session)
        {:ok, text}

      {:error, text, _} ->
        {:error, text}
    end
  end

  defp code(nil), do: {:ok, ""}
  defp code(code) when is_binary(code), do: {:ok, if(String.trim(code) == "", do: "", else: code)}
  defp code(other), do: {:error, "code must be a string, got #{inspect(other, limit: 5)}"}

  defp timeout(nil), do: {:ok, @default_timeout_ms}
  defp timeout(ms) when is_integer(ms) and ms > 0, do: {:ok, min(ms, @max_timeout_ms)}

  defp timeout(other),
    do: {:error, "timeout_ms must be a positive integer, got #{inspect(other)}"}

  @impl true
  def selftest do
    # The kernel alone, with a session kept here, not in the store.
    empty = %{binding: [], env: nil}
    ctx = %{session_id: nil, call_id: "selftest", data_dir: System.tmp_dir!()}

    with {:ok, "3", s} <- EvalKernel.evaluate("x = 1 + 2", empty, ctx, 5_000),
         {:ok, "stdout:\nhi\nresult:\n4", _} <-
           EvalKernel.evaluate(~s|IO.puts("hi"); x + 1|, s, ctx, 5_000),
         {:error, "** (RuntimeError) boom" <> _, nil} <-
           EvalKernel.evaluate(~s|raise "boom"|, s, ctx, 5_000),
         {:ok, ~s|{:error, "eval cannot call eval"}|, _} <-
           EvalKernel.evaluate(~s|tool.("eval", %{"code" => "1"})|, s, ctx, 5_000) do
      :ok
    else
      other -> {:error, other}
    end
  end
end
