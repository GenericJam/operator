defmodule Operator.Test.FlakySecureStore do
  @moduledoc """
  The host's file store, except the operations named by `fail/1` return
  `{:error, :disk_full}`. App-wide (`config :operator, :secure_store, ...`,
  read by the Operator.Auth process), so tests using it are `async: false`.
  """
  @behaviour Operator.SecureStore

  alias Operator.SecureStore.File, as: Store

  @doc "Installs this store; `ops` (`:put`, `:delete`) fail until `fail([])`."
  @spec install(list()) :: :ok
  def install(ops \\ []) do
    Application.put_env(:operator, :secure_store, __MODULE__)
    fail(ops)
  end

  @spec fail(list()) :: :ok
  def fail(ops), do: Application.put_env(:operator, :flaky_secure_store, ops)

  @spec restore() :: :ok
  def restore do
    Application.delete_env(:operator, :secure_store)
    Application.delete_env(:operator, :flaky_secure_store)
  end

  @impl true
  def get(account), do: Store.get(account)

  @impl true
  def put(account, value), do: unless_failing(:put, fn -> Store.put(account, value) end)

  @impl true
  def delete(account), do: unless_failing(:delete, fn -> Store.delete(account) end)

  defp unless_failing(op, fun) do
    if op in Application.get_env(:operator, :flaky_secure_store, []),
      do: {:error, :disk_full},
      else: fun.()
  end
end
