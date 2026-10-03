defmodule Operator.Auth.Transfer do
  @moduledoc """
  Carries a provider login from the Mac to the phone: `mix operator.login`
  seals fresh credentials into a QR text plus six words, the phone's
  `Operator.LoginScanScreen` opens them.

  The QR text is `operator-login:1:<base64url(salt16 | nonce12 | ciphertext+tag)>`.
  The plaintext is JSON `{"provider", "credentials", "created"}` (`created`
  in ms since the epoch), encrypted with AES-256-GCM under
  PBKDF2-HMAC-SHA256(words joined by single spaces, salt, 200 000
  iterations, 32 bytes); the `operator-login:1` header is the associated
  data, so a changed version fails like a changed byte. Codes older than
  10 minutes are refused, and so are codes dated more than a minute ahead
  of the phone's clock (a Mac clock running ahead would otherwise stretch
  the 10 minutes).

  Only `type`, `refresh`, `accountId` and `email` travel: an OpenAI access
  token alone is ~1.8 kB, more than a terminal QR the camera reads well.
  The phone stores `"access" => ""` with `"expires" => 0`, so
  `Operator.Auth.access_token/1` refreshes on first use; the grant was
  minted for the phone and nothing else holds it.

  Words come from the EFF short wordlist 1 (1296 words, CC BY 3.0,
  Electronic Frontier Foundation,
  https://www.eff.org/files/2016/09/08/eff_short_wordlist_1.txt), the list
  Muster's pairing phrases use. Six distinct words are ≈ 62 bits, each
  guess costing a 200 000-round PBKDF2, against a code that lives 10
  minutes on a screen.

  Pure: no processes, no logging (the words and tokens never reach a log).
  """

  @prefix "operator-login"
  @version "1"
  @header @prefix <> ":" <> @version
  @iterations 200_000
  @max_age_ms 10 * 60_000
  @max_skew_ms 60_000
  @word_count 6
  @carried ["type", "refresh", "accountId", "email"]

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on the device (see Operator.Core.Dyn.Samples).
  # credo:disable-for-next-line
  @wordlist_path Path.expand("../../../priv/wordlists/eff_short_wordlist_1.txt", __DIR__)
  @external_resource @wordlist_path
  @words @wordlist_path |> File.read!() |> String.split("\n", trim: true) |> List.to_tuple()
  # Largest multiple of the list size within 16 bits: draws at or above it
  # are rejected so every word is equally likely (no modulo bias).
  @word_draw_limit div(65_536, tuple_size(@words)) * tuple_size(@words)

  @type reason ::
          :not_operator_code
          | :unsupported_version
          | :need_six_words
          | :wrong_words
          | :expired
          | :clock_skew
          | :bad_payload
          | :unknown_provider

  @doc "The wordlist the six words are drawn from, in order."
  @spec wordlist() :: [String.t()]
  def wordlist, do: Tuple.to_list(@words)

  @doc """
  Seals `creds` (pi's auth.json entry, string keys) for `provider` into the
  QR text and the six words that open it. `opts[:now]` (ms) stamps the code;
  it defaults to the current time.
  """
  @spec seal(atom(), map(), keyword()) :: {String.t(), String.t()}
  def seal(provider, creds, opts \\ []) when is_atom(provider) and is_map(creds) do
    words = new_words()
    salt = :crypto.strong_rand_bytes(16)
    nonce = :crypto.strong_rand_bytes(12)

    plaintext =
      Jason.encode!(%{
        "provider" => Atom.to_string(provider),
        "credentials" => Map.take(creds, @carried),
        "created" => Keyword.get_lazy(opts, :now, &now/0)
      })

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(words, salt),
        nonce,
        plaintext,
        @header,
        true
      )

    blob = Base.url_encode64(salt <> nonce <> ciphertext <> tag, padding: false)
    {@header <> ":" <> blob, words}
  end

  @doc """
  Recognizes a scanned QR text without the words: `:ok` for an Operator
  login code this version reads.
  """
  @spec check(String.t()) :: :ok | {:error, :not_operator_code | :unsupported_version}
  def check(qr_text) do
    case parse(qr_text) do
      {:ok, _blob} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Opens a scanned QR text with the words typed on the phone (any case,
  separated by spaces or commas). Returns the provider and the credentials
  to hand to `Operator.Auth.put/2`. `opts[:now]` (ms) is the time the age
  check measures against.
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, atom(), map()} | {:error, reason()}
  def open(qr_text, words, opts \\ []) do
    with {:ok, blob} <- parse(qr_text),
         {:ok, words} <- normalize_words(words),
         {:ok, plaintext} <- decrypt(blob, words),
         {:ok, provider, creds, created} <- decode(plaintext),
         :ok <- fresh(created, Keyword.get_lazy(opts, :now, &now/0)) do
      {:ok, provider, creds}
    end
  end

  @doc "A plain sentence for an `open/2` or `check/1` error."
  @spec message(reason()) :: String.t()
  def message(:not_operator_code), do: "That QR isn't an Operator login code."

  def message(:unsupported_version),
    do: "That login code comes from a newer Operator: update the app, then scan again."

  def message(:need_six_words), do: "Type all six words shown on the Mac."

  def message(:wrong_words),
    do: "Those words don't open this code. Check them against the Mac and try again."

  def message(:expired),
    do: "This code is more than 10 minutes old. Run mix operator.login again on the Mac."

  def message(:clock_skew),
    do:
      "This code is dated in the future: check the clocks on the Mac and the phone, then make a new one."

  def message(:bad_payload), do: "The code opened but holds no usable login. Make a new one."

  def message(:unknown_provider),
    do: "This login is for a provider this Operator doesn't know. Update the app."

  # ── internals ──

  defp parse(@header <> ":" <> blob) do
    case Base.url_decode64(blob, padding: false) do
      {:ok, bin} when byte_size(bin) > 16 + 12 + 16 -> {:ok, bin}
      _ -> {:error, :not_operator_code}
    end
  end

  defp parse(@prefix <> ":" <> _other_version), do: {:error, :unsupported_version}
  defp parse(_), do: {:error, :not_operator_code}

  defp normalize_words(input) do
    case input |> String.downcase() |> String.split(~r/[\s,]+/, trim: true) do
      words when length(words) == @word_count -> {:ok, Enum.join(words, " ")}
      _ -> {:error, :need_six_words}
    end
  end

  defp decrypt(<<salt::binary-16, nonce::binary-12, rest::binary>>, words) do
    ciphertext = binary_part(rest, 0, byte_size(rest) - 16)
    tag = binary_part(rest, byte_size(rest), -16)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(words, salt),
           nonce,
           ciphertext,
           @header,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :wrong_words}
    end
  end

  defp decode(plaintext) do
    with {:ok, %{"provider" => p, "credentials" => %{} = creds, "created" => created}}
         when is_binary(p) and is_integer(created) <- Jason.decode(plaintext),
         {:ok, provider} <- provider(p),
         %{"type" => "oauth", "refresh" => refresh} when is_binary(refresh) and refresh != "" <-
           creds do
      {:ok, provider, Map.merge(creds, %{"access" => "", "expires" => 0}), created}
    else
      {:error, :unknown_provider} = err -> err
      _ -> {:error, :bad_payload}
    end
  end

  defp provider(name) do
    case Enum.find(Operator.Auth.providers(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, :unknown_provider}
      provider -> {:ok, provider}
    end
  end

  defp fresh(created, now) when now - created < -@max_skew_ms, do: {:error, :clock_skew}
  defp fresh(created, now) when now - created > @max_age_ms, do: {:error, :expired}
  defp fresh(_created, _now), do: :ok

  defp key(words, salt), do: :crypto.pbkdf2_hmac(:sha256, words, salt, @iterations, 32)

  defp new_words, do: draw([]) |> Enum.join(" ")

  defp draw(words) when length(words) == @word_count, do: words

  defp draw(words) do
    word = elem(@words, uniform_word_index())
    if word in words, do: draw(words), else: draw([word | words])
  end

  defp uniform_word_index do
    <<n::16>> = :crypto.strong_rand_bytes(2)
    if n < @word_draw_limit, do: rem(n, tuple_size(@words)), else: uniform_word_index()
  end

  defp now, do: System.system_time(:millisecond)
end
