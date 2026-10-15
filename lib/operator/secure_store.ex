defmodule Operator.SecureStore do
  @moduledoc """
  Where the app keeps secrets (the provider sign-ins, the cluster's
  identity and cookie, Dyn's approve-all flag): Operator's
  `Rho.CredentialStore` (`config :rho, :credential_store`). Callers go
  through `Rho.CredentialStore`.

  On the phone that is the platform secure store
  (`Operator.Nifs.OperatorSecureStore`: EncryptedSharedPreferences under an
  Android Keystore master key on Android, the Keychain on iOS, under the
  names Operator has always used, so an install keeps its sign-ins). If
  that NIF isn't loaded there (a beams-only deploy onto a native build
  without it), the store fails closed: every call is `{:error,
  :secure_store_unavailable}`, so signing in fails visibly instead of
  writing tokens in plain files. Only off the phone (the host and tests)
  is each key a 0600 file in the data dir (`Rho.CredentialStore.File`).
  `config :operator, :secure_store, Module` swaps the backend.

  Keys and values are UTF-8 strings without NUL bytes (the Android bridge
  round-trips them through Java strings).
  """
  @behaviour Rho.CredentialStore

  alias Operator.Core.Term
  alias Operator.Nifs.OperatorSecureStore

  require Logger

  @impl true
  def get(key) do
    case backend().get(key) do
      # The NIF's "no such key".
      {:ok, nil} -> :error
      other -> other
    end
  end

  @impl true
  def put(key, value), do: backend().put(key, value)

  @impl true
  def delete(key), do: backend().delete(key)

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
  def backend_for(:host, _nif_loaded?), do: Rho.CredentialStore.File
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
  @behaviour Rho.CredentialStore

  @impl true
  def get(_key), do: {:error, :secure_store_unavailable}

  @impl true
  def put(_key, _value), do: {:error, :secure_store_unavailable}

  @impl true
  def delete(_key), do: {:error, :secure_store_unavailable}
end
