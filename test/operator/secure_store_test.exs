defmodule Operator.SecureStoreTest do
  # async: false: the backend override is app-wide.
  use ExUnit.Case, async: false

  alias Operator.Auth
  alias Operator.SecureStore

  test "only off the phone are secrets kept in files; a phone without the NIF fails closed" do
    assert SecureStore.backend_for(:host, false) == SecureStore.File
    assert SecureStore.backend_for(:android, true) == Operator.Nifs.OperatorSecureStore
    assert SecureStore.backend_for(:ios, true) == Operator.Nifs.OperatorSecureStore
    assert SecureStore.backend_for(:android, false) == SecureStore.Unavailable
    assert SecureStore.backend_for(:ios, false) == SecureStore.Unavailable
  end

  test "with the store unavailable, signing in fails and says why" do
    start_supervised!(Auth)
    Application.put_env(:operator, :secure_store, SecureStore.Unavailable)
    on_exit(fn -> Application.delete_env(:operator, :secure_store) end)

    creds = %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}
    assert Auth.put(:anthropic, creds) == {:error, :secure_store_unavailable}
    assert Auth.get(:anthropic) == :error
    assert Auth.access_token(:anthropic) == {:error, :signed_out}
    assert Auth.describe_error(:secure_store_unavailable) =~ "secure store isn't available"
  end
end
