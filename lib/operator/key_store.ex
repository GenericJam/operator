defmodule Operator.KeyStore do
  @moduledoc """
  Holds the OpenRouter key on the device.

  On Android it lives in the platform secure store
  (`Operator.Nifs.OperatorSecureStore`: EncryptedSharedPreferences under an
  Android Keystore master key). Where that NIF isn't loaded (the host and
  tests, or a beams-only deploy onto a native build without it) and on iOS,
  whose Keychain path isn't wired up yet, the key is a 0600 file in the
  app's private data dir. `config :operator, :secure_store, Module` swaps
  the secure store (tests).

  Earlier Android builds kept the key in that file. The first read with the
  secure store moves it: write it to the store, read it back, and delete the
  file only when the two match. A key already in the store wins and a
  leftover file is deleted. `delete/0` (sign-out) removes the key from both.

  The key is never logged or returned over rpc: callers get `present?/0`
  and a SHA-256 fingerprint, not the key.
  """

  alias Operator.Core.Term
  alias Operator.Nifs.OperatorSecureStore

  require Logger

  @file_name "openrouter.key"
  @account "openrouter_api_key"

  @spec put(String.t()) :: :ok | {:error, term()}
  def put(key) when is_binary(key) and byte_size(key) > 0 do
    with :ok <- store(backend(), key), do: activate(key)
  end

  @spec get() :: {:ok, String.t()} | :error
  def get, do: fetch(backend())

  @spec present?() :: boolean()
  def present?, do: match?({:ok, _}, get())

  @doc "First 12 hex chars of sha256(key): enough to tell keys apart, useless to an attacker."
  @spec fingerprint() :: String.t() | nil
  def fingerprint do
    case get() do
      {:ok, key} ->
        :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      :error ->
        nil
    end
  end

  @doc "Hands a stored key to req_llm at boot."
  @spec load() :: :ok | :none
  def load do
    case get() do
      {:ok, key} -> activate(key)
      :error -> :none
    end
  end

  @spec delete() :: :ok | {:error, term()}
  def delete do
    _ = File.rm(path())
    Application.delete_env(:req_llm, :openrouter_api_key)

    case backend() do
      nil -> :ok
      secure -> secure.delete(@account)
    end
  end

  @doc "The secure store in effect, or `nil` for the key file."
  @spec backend() :: module() | nil
  def backend do
    case Application.fetch_env(:operator, :secure_store) do
      {:ok, secure} -> secure
      :error -> detected_backend()
    end
  end

  # Asked once: a module whose on_load failed is retried, and warns, per call.
  defp detected_backend do
    with :unknown <- :persistent_term.get({__MODULE__, :backend}, :unknown) do
      secure =
        if Term.platform() == :android and Code.ensure_loaded?(OperatorSecureStore),
          do: OperatorSecureStore

      :persistent_term.put({__MODULE__, :backend}, secure)
      secure
    end
  end

  defp store(nil, key) do
    path = path()
    File.write!(path, key)
    File.chmod!(path, 0o600)
  end

  defp store(secure, key) do
    with :ok <- secure.put(@account, key) do
      _ = File.rm(path())
      :ok
    end
  end

  defp fetch(nil), do: read_file()

  defp fetch(secure) do
    case secure.get(@account) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        if File.rm(path()) == :ok,
          do: Logger.info("[key_store] deleted a key file left beside the secure store's key")

        {:ok, key}

      {:ok, _none} ->
        migrate(secure)

      {:error, reason} ->
        Logger.error(
          "[key_store] secure store read failed: #{inspect(reason)}; using the key file"
        )

        read_file()
    end
  end

  defp migrate(secure) do
    with {:ok, key} <- read_file() do
      case put_verified(secure, key) do
        :ok ->
          _ = File.rm(path())
          Logger.info("[key_store] moved the key from the key file into the secure store")

        {:error, why} ->
          Logger.error(
            "[key_store] moving the key into the secure store failed (#{why}); keeping the key file"
          )
      end

      {:ok, key}
    end
  end

  defp put_verified(secure, key) do
    case secure.put(@account, key) do
      :ok -> check_read_back(secure, key)
      {:error, reason} -> {:error, "write: #{inspect(reason)}"}
    end
  end

  defp check_read_back(secure, key) do
    case secure.get(@account) do
      {:ok, ^key} ->
        :ok

      other ->
        # Left in place, a value that didn't verify would win over the file on the next read.
        _ = secure.delete(@account)
        {:error, read_back_error(other)}
    end
  end

  defp read_back_error({:error, reason}), do: "read-back: #{inspect(reason)}"
  defp read_back_error({:ok, _different}), do: "read-back didn't match"

  defp read_file do
    case File.read(path()) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _ -> :error
    end
  end

  defp activate(key) do
    ReqLLM.put_key(:openrouter_api_key, key)
  end

  defp path, do: Path.join(Operator.Paths.data_dir(), @file_name)
end

defmodule Operator.Paths do
  @moduledoc "App-private persistent dir: MOB_DATA_DIR on device, _build/host_data on the host."

  @spec data_dir() :: String.t()
  def data_dir do
    dir = System.get_env("MOB_DATA_DIR") || Path.join(File.cwd!(), "_build/host_data")
    File.mkdir_p!(dir)
    dir
  end
end
