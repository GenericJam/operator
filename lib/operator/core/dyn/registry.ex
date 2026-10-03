defmodule Operator.Core.Dyn.Registry do
  @moduledoc """
  Reads the Dyn registry: one ETS table owned (and only written) by
  `Operator.Core.Dyn.Keeper`, named like the Keeper. It maps logical names
  to the current generation's modules:

    * `{:tool, "weather"}` (a tool's `name/0`),
    * `{:screen, "Notes"}` (the module name below `Operator.Dyn.`),
    * `{:module, "Helpers"}` (anything else).

  The whole mapping is one row, `{:generation, n, entries}`, so a switch
  of generations is a single insert: a reader sees the old set or the new
  one, never a mix. Other rows: `{:mode, :booting | :normal | :safe}` and
  `{:config, map}` (the Keeper's data dir and options, for
  `Operator.Core.Dyn`).

  Every read answers sensibly while no Keeper runs (no Dyn layer).
  """

  @type key :: {:tool | :screen | :module, String.t()}

  @spec lookup(key(), atom()) :: {:ok, module()} | :error
  def lookup(key, table), do: Map.fetch(entries(table), key)

  @doc "The current generation's `{name, module}` of `kind`, sorted by name."
  @spec all(:tool | :screen | :module, atom()) :: [{String.t(), module()}]
  def all(kind, table) do
    for {{^kind, name}, mod} <- Enum.sort(entries(table)), do: {name, mod}
  end

  @spec generation(atom()) :: non_neg_integer()
  def generation(table) do
    case read(table, :generation) do
      [{:generation, n, _}] -> n
      [] -> 0
    end
  end

  @spec entries(atom()) :: %{key() => module()}
  def entries(table) do
    case read(table, :generation) do
      [{:generation, _, entries}] -> entries
      [] -> %{}
    end
  end

  @spec mode(atom()) :: :off | :booting | :normal | :safe
  def mode(table) do
    case read(table, :mode) do
      [{:mode, mode}] -> mode
      [] -> :off
    end
  end

  @spec config(atom()) :: {:ok, map()} | {:error, :not_running}
  def config(table) do
    case read(table, :config) do
      [{:config, config}] -> {:ok, config}
      [] -> {:error, :not_running}
    end
  end

  # No table: no Keeper (or one restarting).
  defp read(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end
end
