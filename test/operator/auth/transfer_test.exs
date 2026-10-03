defmodule Operator.Auth.TransferTest do
  use ExUnit.Case, async: true

  alias Operator.Auth.Transfer

  @creds %{
    "type" => "oauth",
    "access" => "sk-ant-oat01-not-a-real-access-token",
    "refresh" => "sk-ant-ort01-not-a-real-refresh-token",
    "expires" => 1_900_000_000_000,
    "email" => "kevin@example.com",
    "accountId" => "11111111-2222-3333-4444-555555555555",
    "orgName" => "not carried"
  }

  test "the words open what was sealed; only the refresh side travels" do
    {qr, words} = Transfer.seal(:anthropic, @creds)

    assert "operator://login?c=" <> _ = qr
    assert Transfer.check(qr) == :ok

    assert Transfer.open(qr, words) ==
             {:ok, :anthropic,
              %{
                "type" => "oauth",
                "access" => "",
                "refresh" => @creds["refresh"],
                "expires" => 0,
                "email" => "kevin@example.com",
                "accountId" => @creds["accountId"]
              }}
  end

  test "the words open the code however they are typed" do
    {qr, words} = Transfer.seal(:openai_codex, Map.drop(@creds, ["email"]))
    typed = "  " <> (words |> String.upcase() |> String.replace(" ", " ,\n ")) <> " "

    assert {:ok, :openai_codex, %{"refresh" => _}} = Transfer.open(qr, typed)
  end

  test "six distinct words, all from the list" do
    {_qr, words} = Transfer.seal(:anthropic, @creds)
    list = Transfer.wordlist()
    words = String.split(words, " ")

    assert MapSet.size(MapSet.new(list)) == 1296
    assert [_, _, _, _, _, _] = words
    assert Enum.uniq(words) == words
    assert Enum.all?(words, &(&1 in list))
  end

  test "other words, or too few, don't open it" do
    {qr, words} = Transfer.seal(:anthropic, @creds)
    [first | rest] = String.split(words, " ")
    other = Enum.find(Transfer.wordlist(), &(&1 not in [first | rest]))

    assert Transfer.open(qr, Enum.join([other | rest], " ")) == {:error, :wrong_words}
    assert Transfer.open(qr, Enum.join(rest, " ")) == {:error, :need_six_words}
  end

  test "a changed byte fails authentication" do
    {"operator://login?c=" <> blob, words} = Transfer.seal(:anthropic, @creds)
    bin = Base.url_decode64!(blob, padding: false)
    at = byte_size(bin) - 20
    <<head::binary-size(^at), byte, tail::binary>> = bin
    tampered = Base.url_encode64(head <> <<Bitwise.bxor(byte, 1)>> <> tail, padding: false)

    assert Transfer.open("operator://login?c=" <> tampered, words) == {:error, :wrong_words}
  end

  test "codes older than ten minutes are refused" do
    now = System.system_time(:millisecond)
    {qr, words} = Transfer.seal(:anthropic, @creds, now: now - 10 * 60_000)

    assert {:ok, :anthropic, _} = Transfer.open(qr, words, now: now)
    assert Transfer.open(qr, words, now: now + 1) == {:error, :expired}
  end

  test "codes dated more than a minute ahead are refused, a little skew is not" do
    now = System.system_time(:millisecond)
    {qr, words} = Transfer.seal(:anthropic, @creds, now: now + 60_000)

    assert {:ok, :anthropic, _} = Transfer.open(qr, words, now: now)
    assert Transfer.open(qr, words, now: now - 1) == {:error, :clock_skew}

    {qr, words} = Transfer.seal(:anthropic, @creds, now: now + 24 * 3_600_000)
    assert Transfer.open(qr, words, now: now) == {:error, :clock_skew}
  end

  test "other versions and other QR codes are told apart" do
    {"operator://login?c=" <> blob, words} = Transfer.seal(:anthropic, @creds)

    assert {:ok, :anthropic, _} = Transfer.open("operator://login?v=1&c=" <> blob, words)

    assert Transfer.open("operator://login?v=2&c=" <> blob, words) ==
             {:error, :unsupported_version}

    assert Transfer.check("operator://login?v=2&c=" <> blob) == {:error, :unsupported_version}
    assert Transfer.check("operator-login:1:" <> blob) == {:error, :not_operator_code}
    assert Transfer.check("https://example.com/") == {:error, :not_operator_code}
    assert Transfer.check("operator://login?c=short") == {:error, :not_operator_code}
    assert Transfer.check("operator://handoff?c=" <> blob) == {:error, :not_operator_code}
    assert Transfer.open("WIFI:S:home;;", words) == {:error, :not_operator_code}
  end
end
