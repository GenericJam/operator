defmodule Operator.Cluster.Identity do
  @moduledoc """
  This node's cluster identity: a P-256 key and a self-signed certificate
  whose SHA-256 fingerprint is what peers pin (`Operator.Cluster.Tls`).

  Made on first use and kept in the platform secure store
  (`Operator.SecureStore`, account `"cluster_identity"`, one PEM with the
  certificate and the key); never written anywhere else. The certificate's
  common name, `operator_<10 random hex digits>`, is also the name part of
  the node's name (`Operator.Cluster`).

  `generate/1` and the PEM helpers are shared with `mix
  operator.cluster.peer`, which makes the identity of a node that isn't a
  phone (a Nerves device, a Mac).
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(:tbs, :OTPTBSCertificate, Record.extract(:OTPTBSCertificate, from_lib: @hrl))

  Record.defrecordp(
    :sig_alg,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :pk_alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(:validity, :Validity, Record.extract(:Validity, from_lib: @hrl))

  Record.defrecordp(
    :atv,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: @hrl)
  )

  Record.defrecordp(:ext, :Extension, Record.extract(:Extension, from_lib: @hrl))
  Record.defrecordp(:ec_key, :ECPrivateKey, Record.extract(:ECPrivateKey, from_lib: @hrl))
  Record.defrecordp(:ec_point, :ECPoint, Record.extract(:ECPoint, from_lib: @hrl))

  @account "cluster_identity"
  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @common_name {2, 5, 4, 3}
  @key_usage {2, 5, 29, 15}
  @basic_constraints {2, 5, 29, 19}

  @enforce_keys [:cert, :key, :fingerprint]
  defstruct [:cert, :key, :fingerprint]

  @type t :: %__MODULE__{cert: binary(), key: tuple(), fingerprint: String.t()}

  @doc "This node's identity, made and stored on first use."
  @spec load_or_create() :: {:ok, t()} | {:error, term()}
  def load_or_create do
    case Operator.SecureStore.get(@account) do
      {:ok, pem} when is_binary(pem) ->
        from_pem(pem)

      {:ok, nil} ->
        identity = new()

        with :ok <- Operator.SecureStore.put(@account, to_pem(identity)),
             do: {:ok, identity}

      {:error, _} = error ->
        error
    end
  end

  @doc "The stored identity, without making one."
  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    case Operator.SecureStore.get(@account) do
      {:ok, pem} when is_binary(pem) -> from_pem(pem)
      {:ok, nil} -> {:error, :no_identity}
      {:error, _} = error -> error
    end
  end

  @doc "Removes the stored identity (a cluster reset with a new identity)."
  @spec delete() :: :ok | {:error, term()}
  def delete, do: Operator.SecureStore.delete(@account)

  @doc "A fresh identity named `operator_<10 random hex digits>`."
  @spec new() :: t()
  def new, do: generate("operator_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower))

  @doc "A fresh identity with the given common name (`mix operator.cluster.peer`)."
  @spec generate(String.t()) :: t()
  def generate(common_name) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    cert = sign(common_name, key)
    %__MODULE__{cert: cert, key: key, fingerprint: fingerprint(cert)}
  end

  @doc "The lowercase hex SHA-256 of a DER certificate (what `openssl x509 -fingerprint -sha256` shows)."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der),
    do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)

  @doc "The name part of the node this identity's certificate names (its common name)."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{cert: cert}), do: common_name(cert)

  @doc "The common name in a DER certificate, if any."
  @spec common_name(binary()) :: String.t() | nil
  def common_name(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:rdnSequence, rdns} = tbs(tbs, :subject)

    Enum.find_value(List.flatten(rdns), fn
      atv(type: @common_name, value: {:utf8String, name}) -> to_string(name)
      _ -> nil
    end)
  end

  @doc "The certificate and key as one PEM."
  @spec to_pem(t()) :: String.t()
  def to_pem(%__MODULE__{cert: cert, key: key}) do
    :public_key.pem_encode([
      {:Certificate, cert, :not_encrypted},
      :public_key.pem_entry_encode(:ECPrivateKey, key)
    ])
  end

  @doc "The certificate alone, as PEM."
  @spec cert_pem(t()) :: String.t()
  def cert_pem(%__MODULE__{cert: cert}),
    do: :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])

  @doc "The key alone, as PEM."
  @spec key_pem(t()) :: String.t()
  def key_pem(%__MODULE__{key: key}),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  @doc "Reads `to_pem/1`'s output back."
  @spec from_pem(String.t()) :: {:ok, t()} | {:error, :bad_identity}
  def from_pem(pem) do
    entries = :public_key.pem_decode(pem)

    with {:Certificate, cert, _} <- List.keyfind(entries, :Certificate, 0),
         {:ECPrivateKey, _, _} = entry <- List.keyfind(entries, :ECPrivateKey, 0) do
      key = :public_key.pem_entry_decode(entry)
      {:ok, %__MODULE__{cert: cert, key: key, fingerprint: fingerprint(cert)}}
    else
      _ -> {:error, :bad_identity}
    end
  end

  # A self-signed end-entity certificate: ECDSA P-256 / SHA-256, valid for
  # 100 years (pinning, not expiry, is what is trusted), key usage
  # digitalSignature, not a CA.
  defp sign(common_name, key) do
    name = {:rdnSequence, [[atv(type: @common_name, value: {:utf8String, common_name})]]}
    alg = sig_alg(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE)

    cert =
      tbs(
        version: :v3,
        serialNumber: :binary.decode_unsigned(:crypto.strong_rand_bytes(8)),
        signature: alg,
        issuer: name,
        validity:
          validity(
            notBefore: {:generalTime, ~c"20240101000000Z"},
            notAfter: {:generalTime, ~c"21240101000000Z"}
          ),
        subject: name,
        subjectPublicKeyInfo:
          spki(
            algorithm: pk_alg(algorithm: @ec_public_key, parameters: {:namedCurve, @p256}),
            subjectPublicKey: ec_point(point: ec_key(key, :publicKey))
          ),
        extensions: [
          ext(extnID: @key_usage, critical: true, extnValue: [:digitalSignature]),
          ext(
            extnID: @basic_constraints,
            critical: true,
            extnValue: {:BasicConstraints, false, :asn1_NOVALUE}
          )
        ]
      )

    :public_key.pkix_sign(cert, key)
  end
end
