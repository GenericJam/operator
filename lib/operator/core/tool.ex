defmodule Operator.Core.Tool do
  @moduledoc """
  The name `Rho.Tool` had before the agent core moved to rho, kept because
  Dyn code on phones names it: the guide told the agent to write
  `@behaviour Operator.Core.Tool`, and every Dyn generation is rebuilt and
  checked again on a new Core. It is the same behaviour (its callbacks are
  `Rho.Tool`'s), and Dyn code may use it (`config :rho, :dyn, allowed:`).
  New code says `Rho.Tool`.
  """

  @doc false
  defdelegate behaviour_info(kind), to: Rho.Tool
end
