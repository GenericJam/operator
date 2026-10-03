defmodule Operator.Core.ToolRegistry do
  @moduledoc """
  The tools the agent can call, by name. The Core's own (and any
  registered at runtime) live in one ETS table owned by this process; the
  current Dyn generation's come from `Operator.Core.Dyn`'s registry, read
  on every call, so a generation switch (activation or revert) changes the
  tool set at once, with nothing to register or unregister. A Core tool's
  name always wins. The loop reads the list at the start of every model
  call, so a new tool is offered from the next call on.
  """
  use GenServer

  alias Operator.Core.Dyn
  alias Operator.Core.Tool

  @table __MODULE__
  @core_tools [
    Operator.Core.Tools.Notes,
    Operator.Core.Tools.ReadArtifact,
    Operator.Core.Tools.HttpGet,
    Operator.Core.Tools.Clipboard,
    Operator.Core.Tools.Location,
    Operator.Core.Tools.Notify,
    Operator.Core.Tools.CameraPhoto,
    Operator.Core.Tools.PickPhotos,
    # The agent's own Dyn layer; activating and reverting need the human.
    Operator.Core.Tools.DynFiles,
    Operator.Core.Tools.DynRead,
    Operator.Core.Tools.DynWrite,
    Operator.Core.Tools.DynEdit,
    Operator.Core.Tools.DynDelete,
    Operator.Core.Tools.DynReset,
    Operator.Core.Tools.DynPropose,
    Operator.Core.Tools.DynStatus
  ]

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
      [] -> Dyn.lookup({:tool, name})
    end
  end

  @doc "All tool modules (the Core's, then the current Dyn generation's), sorted by name."
  @spec list() :: [module()]
  def list do
    core = :ets.tab2list(@table)

    dyn = for {name, mod} <- Dyn.tools(), not :ets.member(@table, name), do: {name, mod}

    (core ++ dyn) |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  @doc "The Core's own tools (a Dyn tool may not take one of their names)."
  @spec core_tools() :: [module()]
  def core_tools, do: @core_tools

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
