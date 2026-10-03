defmodule Operator.Core.ToolRegistry do
  @moduledoc """
  The tools the agent can call, by name: one ETS table owned by the Core.
  The loop reads it at the start of every model call, so a tool registered
  at runtime (step 2: a Dyn generation's tools) is offered from the next
  call on.
  """
  use GenServer

  alias Operator.Core.Tool

  @table __MODULE__
  @core_tools [Operator.Core.Tools.Notes, Operator.Core.Tools.ReadArtifact]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec register(module()) :: :ok | {:error, :not_a_tool}
  def register(module), do: GenServer.call(__MODULE__, {:register, module})

  @spec unregister(String.t()) :: :ok
  def unregister(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc "All registered tool modules, sorted by name."
  @spec list() :: [module()]
  def list, do: @table |> :ets.tab2list() |> Enum.sort() |> Enum.map(&elem(&1, 1))

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    Enum.each(Keyword.get(opts, :tools, @core_tools), &put/1)
    {:ok, nil}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    if Tool.tool?(module),
      do: {:reply, put(module), state},
      else: {:reply, {:error, :not_a_tool}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  defp put(module) do
    true = :ets.insert(@table, {module.name(), module})
    :ok
  end
end
