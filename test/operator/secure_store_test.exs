defmodule Operator.SecureStoreTest do
  # async: false: the backend override is app-wide.
  use ExUnit.Case, async: false

  alias Operator.SecureStore
  alias Rho.Auth

  defmodule NifLike do
    @moduledoc "Answers like the platform NIF: a missing key is `{:ok, nil}`."
    def get("present"), do: {:ok, "value"}
    def get(_key), do: {:ok, nil}
    def put(_key, _value), do: :ok
    def delete(_key), do: :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:operator, :secure_store) end)
  end

  test "only off the phone are secrets kept in files; a phone without the NIF fails closed" do
    assert SecureStore.backend_for(:host, false) == Rho.CredentialStore.File
    assert SecureStore.backend_for(:android, true) == Operator.Nifs.OperatorSecureStore
    assert SecureStore.backend_for(:ios, true) == Operator.Nifs.OperatorSecureStore
    assert SecureStore.backend_for(:android, false) == SecureStore.Unavailable
    assert SecureStore.backend_for(:ios, false) == SecureStore.Unavailable
  end

  test "the NIF's missing key is rho's :error" do
    Application.put_env(:operator, :secure_store, NifLike)
    assert Rho.CredentialStore.get("present") == {:ok, "value"}
    assert Rho.CredentialStore.get("auth:anthropic") == :error
  end

  test "with the store unavailable, signing in fails and says why" do
    start_supervised!(Auth)
    Application.put_env(:operator, :secure_store, SecureStore.Unavailable)

    creds = %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}
    assert Auth.put(:anthropic, creds) == {:error, :secure_store_unavailable}
    assert Auth.get(:anthropic) == :error
    assert Auth.credential(:anthropic) == {:error, :signed_out}
    assert Auth.describe_error(:secure_store_unavailable) =~ "secure store isn't available"
  end
end
