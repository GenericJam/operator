defmodule Operator.Nifs.OperatorSecureStore do
  @moduledoc """
  Statically-linked NIF stub for `:operator_secure_store`, ported from
  muster_app's `:muster_secure_store`: EncryptedSharedPreferences under an
  Android Keystore master key on Android (through `OperatorSecureStore.kt`),
  the Keychain on iOS. The C side is `c_src/operator_secure_store.c`.

  The init function `operator_secure_store_nif_init` is registered in the
  per-app `priv/generated/driver_tab_{ios,android}.zig` static table
  (regenerated from `mob.exs`'s `:static_nifs` on every native build). At
  BEAM startup the runtime resolves `load_nif/2` against that table and
  binds the C functions to these placeholders. Off the phone, or on a
  native build that predates the NIF, `load_nif/2` fails and so does
  loading this module.

  Errors are `{:error, {:sec, os_status}}` from Security.framework on iOS
  and `{:error, {:jni, reason}}` from the Android bridge, where reason is
  one of `:no_jenv`, `:bridge_init_failed` (`OperatorSecureStore.init/1`
  didn't run before the BEAM started), `:commit_failed`,
  `:newstring_failed`, `:call_failed`, `:getchars_failed` or `:alloc`.
  """

  @behaviour Operator.SecureStore

  @on_load :load_nif

  @doc false
  def load_nif do
    # Static NIFs don't read a path — the second arg to load_nif must
    # still be passed but is ignored when the module is in the static
    # NIF table. Pass 0 by convention.
    :erlang.load_nif(~c"operator_secure_store", 0)
  end

  @impl true
  def get(_account), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def put(_account, _value), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def delete(_account), do: :erlang.nif_error(:nif_not_loaded)
end
