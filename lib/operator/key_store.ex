defmodule Operator.KeyStore do
  @moduledoc """
  Holds the OpenRouter key on the device.

  Spike storage: a 0600 file in the app's private data dir (Android
  `getFilesDir()`, only readable by this app's uid, not backed up to the
  user's view). The real build should move it to the platform secure store
  (Keychain / EncryptedSharedPreferences); muster_app's
  `muster_secure_store` NIF + Kotlin shim is the template, but it is native
  code, so it is out of scope for the spike.

  The key is never logged or returned over rpc: callers get `present?/0`
  and a SHA-256 fingerprint, not the key.
  """

  @file_name "openrouter.key"

  @spec put(String.t()) :: :ok
  def put(key) when is_binary(key) and byte_size(key) > 0 do
    path = path()
    File.write!(path, key)
    File.chmod!(path, 0o600)
    activate(key)
  end

  @spec get() :: {:ok, String.t()} | :error
  def get do
    case File.read(path()) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _ -> :error
    end
  end

  @spec present?() :: boolean()
  def present?, do: match?({:ok, _}, get())

  @doc "First 12 hex chars of sha256(key): enough to tell keys apart, useless to an attacker."
  @spec fingerprint() :: String.t() | nil
  def fingerprint do
    case get() do
      {:ok, key} -> :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)
      :error -> nil
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

  @spec delete() :: :ok
  def delete do
    _ = File.rm(path())
    Application.delete_env(:req_llm, :openrouter_api_key)
    :ok
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
