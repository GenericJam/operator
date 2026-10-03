defmodule Operator.Core.Tools.PhoneTool do
  @moduledoc """
  What the phone tools share: the request through `Operator.Core.Phone`
  (`ctx[:phone_host]` overrides the host in tests and selftests) and a
  selftest against a stand-in host that answers like the real one.
  """

  alias Operator.Core.Phone

  @spec call(Phone.action(), map(), map(), timeout()) :: {:ok, term()} | {:error, String.t()}
  def call(action, args, ctx, timeout),
    do: Phone.request(action, args, timeout, Map.get_lazy(ctx, :phone_host, &Phone.host/0))

  @doc "Runs `fun.(ctx)` against a host that answers `answer`; `check` judges the result."
  @spec selftest((map() -> term()), term(), (term() -> boolean())) :: :ok | {:error, String.t()}
  def selftest(fun, answer, check) do
    host =
      spawn(fn ->
        receive do
          {:phone_request, ref, from, _action, _args} -> Phone.reply(from, ref, answer)
        after
          5_000 -> :ok
        end
      end)

    result = fun.(%{phone_host: host})
    if check.(result), do: :ok, else: {:error, "selftest: #{inspect(result)}"}
  end
end
