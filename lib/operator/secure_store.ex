defmodule Operator.SecureStore do
  @moduledoc """
  Where the app keeps secrets (the provider sign-ins, `Operator.Auth`).

  On the phone that is the platform secure store
  (`Operator.Nifs.OperatorSecureStore`: EncryptedSharedPreferences under an
  Android Keystore master key on Android, the Keychain on iOS). If that NIF
  isn't loaded there (a beams-only deploy onto a native build without it),
  the store fails closed: every call is `{:error, :secure_store_unavailable}`
  (`Operator.SecureStore.Unavailable`), so signing in fails visibly instead
  of writing tokens in plain files. Only off the phone (the host and tests)
  is each account a 0600 file in the app's data dir
  (`Operator.SecureStore.File`). `config :operator, :secure_store, Module`
  swaps the backend.

  Accounts and values are UTF-8 strings without NUL bytes (the Android bridge
  round-trips them through Java strings).
  """

  alias Operator.Core.Term
  alias Operator.Nifs.OperatorSecureStore

  require Logger

  @doc "The value at `account`; `{:ok, nil}` when there is none."
  @callback get(account :: String.t()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Upserts `account`, durably (`:ok` means written, not queued)."
  @callback put(account :: String.t(), value :: String.t()) :: :ok | {:error, term()}

  @doc "Removes `account`; removing an absent one is `:ok`."
  @callback delete(account :: String.t()) :: :ok | {:error, term()}

  @spec get(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get(account), do: backend().get(account)

  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(account, value), do: backend().put(account, value)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(account), do: backend().delete(account)

  @doc "The backend in effect."
  @spec backend() :: module()
  def backend do
    case Application.fetch_env(:operator, :secure_store) do
      {:ok, secure} -> secure
      :error -> detected_backend()
    end
  end

  @doc false
  # The backend for `platform`, given whether the NIF loaded.
  @spec backend_for(:android | :ios | :host, boolean()) :: module()
  def backend_for(:host, _nif_loaded?), do: Operator.SecureStore.File
  def backend_for(_phone, true), do: OperatorSecureStore
  def backend_for(_phone, false), do: Operator.SecureStore.Unavailable

  # Asked once: a module whose on_load failed is retried, and warns, per call.
  defp detected_backend do
    with :unknown <- :persistent_term.get({__MODULE__, :backend}, :unknown) do
      platform = Term.platform()

      secure =
        backend_for(platform, platform != :host and Code.ensure_loaded?(OperatorSecureStore))

      if secure == Operator.SecureStore.Unavailable,
        do:
          Logger.error("[secure_store] the secure store NIF isn't loaded: secrets can't be kept")

      :persistent_term.put({__MODULE__, :backend}, secure)
      secure
    end
  end
end

defmodule Operator.SecureStore.Unavailable do
  @moduledoc "The phone's backend when its secure store NIF isn't loaded: refuses everything."
  @behaviour Operator.SecureStore

  @impl true
  def get(_account), do: {:error, :secure_store_unavailable}

  @impl true
  def put(_account, _value), do: {:error, :secure_store_unavailable}

  @impl true
  def delete(_account), do: {:error, :secure_store_unavailable}
end

defmodule Operator.SecureStore.File do
  @moduledoc """
  The off-phone backend (host, tests): one 0600 file per account under
  `<data dir>/secure/`, the account name made filename-safe.
  """
  @behaviour Operator.SecureStore

  @impl true
  def get(account) do
    case File.read(path(account)) do
      {:ok, value} -> {:ok, value}
      {:error, :enoent} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @impl true
  def put(account, value) do
    path = path(account)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    # Created 0600 before the secret is written; renamed over the old file.
    with :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, value) do
      File.rename(tmp, path)
    end
  end

  @impl true
  def delete(account) do
    case File.rm(path(account)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  defp path(account),
    do:
      Path.join([Operator.Paths.data_dir(), "secure", String.replace(account, ~r/[^\w.-]/, "_")])
end
