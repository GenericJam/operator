defmodule Operator.Certs do
  @moduledoc """
  Loads the Mozilla CA bundle into `:public_key` before any HTTPS call.

  Android has no system CA store at the paths OTP's
  `:public_key.cacerts_load/0` knows, so the first Finch/Mint TLS connect
  raises "default CA trust store not available". The bundle is castore's
  PEM, embedded in this module at compile time (deps' priv/ is not shipped
  to the device), written to the cache dir, and loaded with
  `Mob.Certs.load_cacerts!/1`. Same pattern as muster_app.
  """

  @cacerts_path Path.expand(Path.join([__DIR__, "../..", "deps/castore/priv/cacerts.pem"]))
  @external_resource @cacerts_path
  @cacerts_pem File.read!(@cacerts_path)

  @spec install!() :: :ok
  def install! do
    # Not System.tmp_dir!/0: no TMPDIR is writable in Android's app sandbox.
    path = Path.join(Mob.Storage.dir(:cache), "operator_cacerts.pem")
    File.write!(path, @cacerts_pem)
    Mob.Certs.load_cacerts!(path)
  end
end
