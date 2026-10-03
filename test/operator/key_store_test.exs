defmodule Operator.KeyStoreTest do
  # async: false: the key file and the :secure_store override are app-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Operator.KeyStore
  alias Operator.Test.FakeSecureStore

  @key "sk-or-v1-test-not-a-real-key"

  setup do
    Application.put_env(:operator, :secure_store, FakeSecureStore)

    on_exit(fn ->
      Application.delete_env(:operator, :secure_store)
      KeyStore.delete()
    end)
  end

  # Where builds before the secure store kept the key.
  defp key_file, do: Path.join(Operator.Paths.data_dir(), "openrouter.key")

  test "a key file with an empty secure store moves into the store and the file goes" do
    File.write!(key_file(), @key)

    assert KeyStore.get() == {:ok, @key}
    assert Map.values(FakeSecureStore.entries()) == [@key]
    refute File.exists?(key_file())
    assert KeyStore.get() == {:ok, @key}
  end

  test "a key in the secure store wins and a leftover file is deleted" do
    :ok = KeyStore.put(@key)
    File.write!(key_file(), "sk-or-v1-stale")

    assert KeyStore.get() == {:ok, @key}
    refute File.exists?(key_file())
    assert Map.values(FakeSecureStore.entries()) == [@key]
  end

  test "a read-back that doesn't match keeps the file and logs, without the key" do
    File.write!(key_file(), @key)
    FakeSecureStore.reads(:corrupt)

    log = capture_log(fn -> assert KeyStore.get() == {:ok, @key} end)

    assert File.read!(key_file()) == @key
    assert log =~ "keeping the key file"
    refute log =~ @key
    # The unverified value is gone, so the next read tries the file again.
    assert FakeSecureStore.entries() == %{}
  end

  test "an unreadable secure store falls back to the file and leaves it" do
    File.write!(key_file(), @key)
    FakeSecureStore.reads({:error, {:jni, :bridge_init_failed}})

    log = capture_log(fn -> assert KeyStore.get() == {:ok, @key} end)

    assert File.read!(key_file()) == @key
    assert log =~ "bridge_init_failed"
    assert FakeSecureStore.entries() == %{}
  end

  test "delete removes the key from the secure store and the file" do
    :ok = KeyStore.put(@key)
    File.write!(key_file(), @key)

    assert KeyStore.delete() == :ok

    assert KeyStore.get() == :error
    assert FakeSecureStore.entries() == %{}
    refute File.exists?(key_file())
  end

  test "off the phone the key stays in a 0600 file" do
    Application.delete_env(:operator, :secure_store)

    :ok = KeyStore.put(@key)

    assert KeyStore.backend() == nil
    assert File.read!(key_file()) == @key
    assert File.stat!(key_file()).mode |> Bitwise.band(0o777) == 0o600
  end
end
