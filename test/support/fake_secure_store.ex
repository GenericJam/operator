defmodule Operator.Test.FakeSecureStore do
  @moduledoc """
  Stands in for `Operator.Nifs.OperatorSecureStore` in host tests
  (`config :operator, :secure_store, ...`). Entries live in the calling
  process's dictionary, so every test starts with an empty store.
  """
  @behaviour Operator.SecureStore

  @doc "Every entry, account => value."
  @spec entries() :: %{String.t() => String.t()}
  def entries, do: Process.get(:fake_secure_store, %{})

  @doc "How `get/1` answers from now on: truthfully, with a different value, or with an error."
  @spec reads(:ok | :corrupt | {:error, term()}) :: :ok
  def reads(mode) do
    Process.put(:fake_secure_store_reads, mode)
    :ok
  end

  @impl true
  def get(account) do
    case {Process.get(:fake_secure_store_reads, :ok), Map.get(entries(), account)} do
      {{:error, _} = error, _} -> error
      {:corrupt, value} when is_binary(value) -> {:ok, value <> "-corrupted"}
      {_, value} -> {:ok, value}
    end
  end

  @impl true
  def put(account, value) do
    Process.put(:fake_secure_store, Map.put(entries(), account, value))
    :ok
  end

  @impl true
  def delete(account) do
    Process.put(:fake_secure_store, Map.delete(entries(), account))
    :ok
  end
end
