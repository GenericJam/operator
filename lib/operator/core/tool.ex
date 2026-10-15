defmodule Operator.Core.Tool do
  @moduledoc """
  The name `Rho.Tool` had before the agent core moved to rho, kept because
  Dyn code on phones names it: the guide told the agent to write
  `@behaviour Operator.Core.Tool`, and every Dyn generation is rebuilt and
  checked again on a new Core. It is the same behaviour (its callbacks are
  `Rho.Tool`'s) with the same functions, and Dyn code may use it
  (`config :rho, :dyn, allowed:`). New code says `Rho.Tool`.
  """

  @doc false
  defdelegate behaviour_info(kind), to: Rho.Tool

  defdelegate default_timeout_ms(), to: Rho.Tool
  defdelegate timeout_ms(module), to: Rho.Tool
  defdelegate concurrency(module), to: Rho.Tool
  defdelegate tool?(module), to: Rho.Tool
  defdelegate to_req_llm(module), to: Rho.Tool
end
