defmodule Operator.Tools.AddNumbers do
  @moduledoc "Spike tool: adds two integers, so a tool-call round trip has a checkable answer."
  use Jido.Action,
    name: "add_numbers",
    schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()}),
    description: "Add two integers and return their sum."

  @impl true
  def run(%{a: a, b: b}, _context), do: {:ok, %{sum: a + b}}
end

defmodule Operator.Jido do
  @moduledoc "The app's Jido instance (agent supervisor, registry, task pool)."
  use Jido, otp_app: :operator
end

defmodule Operator.Agent do
  @moduledoc """
  The spike's Jido.AI ReAct agent (one tool), started without network by
  `Operator.Diag.agent/0`; the model is the `:operator` alias
  (`config :jido_ai, :model_aliases`). The chat uses `Operator.Core.Loop`.
  """
  use Jido.AI.Agent,
    name: "operator_agent",
    model: :operator,
    tools: [Operator.Tools.AddNumbers],
    max_iterations: 4,
    system_prompt: "You are Operator. Use the add_numbers tool for any arithmetic."
end
