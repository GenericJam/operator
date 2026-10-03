defmodule Operator.SecureStore do
  @moduledoc """
  `Operator.KeyStore` reaches the secure store through this contract so host
  tests can swap `Operator.Nifs.OperatorSecureStore`, which only loads on the
  phone, for a fake (`config :operator, :secure_store, Module`).

  Accounts and values are UTF-8 strings without NUL bytes (the Android bridge
  round-trips them through Java strings).
  """

  @doc "The value at `account`; `{:ok, nil}` when there is none."
  @callback get(account :: String.t()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Upserts `account`, durably (`:ok` means written, not queued)."
  @callback put(account :: String.t(), value :: String.t()) :: :ok | {:error, term()}

  @doc "Removes `account`; removing an absent one is `:ok`."
  @callback delete(account :: String.t()) :: :ok | {:error, term()}
end
