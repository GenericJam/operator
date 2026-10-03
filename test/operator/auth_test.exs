defmodule Operator.AuthTest do
  # async: false: the sign-ins live in the app-wide secure store.
  use ExUnit.Case, async: false

  alias Operator.Auth
  alias Operator.Test.FlakySecureStore

  @moduletag :capture_log

  setup do
    on_exit(fn -> for p <- Auth.providers(), do: Operator.SecureStore.delete("auth:#{p}") end)
  end

  defp now, do: System.os_time(:millisecond)

  defp creds(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "oauth",
        "access" => "at-1",
        "refresh" => "rt-1",
        "expires" => now() + 3_600_000
      },
      extra
    )
  end

  # A token endpoint that counts its calls, answers after `delay_ms`, and
  # rotates the refresh token.
  defp endpoint(status \\ 200, delay_ms \\ 0) do
    test = self()

    fn req ->
      body = IO.iodata_to_binary(req.body)

      params =
        if Req.Request.get_header(req, "content-type") == ["application/json"],
          do: Jason.decode!(body),
          else: URI.decode_query(body)

      send(test, {:refresh_request, params})
      Process.sleep(delay_ms)

      body =
        if status == 200,
          do: %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 3600},
          else: %{"error" => "invalid_grant", "error_description" => "Refresh token expired"}

      Req.Response.new(status: status, body: Jason.encode!(body))
    end
  end

  test "put/get/status/delete; subscribers hear every change" do
    start_supervised!(Auth)
    :ok = Auth.subscribe()

    assert Auth.status() == %{
             anthropic: %{signed_in: false, email: nil, expires: nil},
             openai_codex: %{signed_in: false, email: nil, expires: nil}
           }

    c = creds(%{"email" => "k@example.com", "accountId" => "acct"})
    assert :ok = Auth.put(:openai_codex, c)
    assert_received {:operator_auth, :changed}
    assert Auth.get(:openai_codex) == {:ok, c}

    assert Auth.status().openai_codex == %{
             signed_in: true,
             email: "k@example.com",
             expires: c["expires"]
           }

    refute Auth.signed_in?(:anthropic)

    assert {:ok, %{token: "at-1", account_id: "acct"}} = Auth.access_token(:openai_codex)

    assert :ok = Auth.delete(:openai_codex)
    assert_received {:operator_auth, :changed}
    assert Auth.get(:openai_codex) == :error
    assert Auth.access_token(:openai_codex) == {:error, :signed_out}
  end

  test "put refuses what isn't pi's OAuth credential" do
    start_supervised!(Auth)

    assert {:error, :invalid_credentials} = Auth.put(:anthropic, Map.delete(creds(), "refresh"))
    assert {:error, :invalid_credentials} = Auth.put(:anthropic, creds(%{"refresh" => ""}))
    assert {:error, :invalid_credentials} = Auth.put(:anthropic, creds(%{"type" => "api_key"}))
    assert {:error, :unknown_provider} = Auth.put(:mistral, creds())
    assert Auth.get(:anthropic) == :error
  end

  test "on the host the store is a 0600 file" do
    start_supervised!(Auth)
    :ok = Auth.put(:anthropic, creds())

    path = Path.join([Operator.Paths.data_dir(), "secure", "auth_anthropic"])
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a token near expiry is refreshed first and the rotated refresh token stored" do
    start_supervised!({Auth, respond: endpoint()})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now() + 60_000, "email" => "k@example.com"}))

    assert {:ok, %{token: "at-2"}} = Auth.access_token(:anthropic)
    assert_received {:refresh_request, %{"refresh_token" => "rt-1"}}

    assert {:ok, %{"access" => "at-2", "refresh" => "rt-2", "email" => "k@example.com"} = stored} =
             Auth.get(:anthropic)

    assert stored["expires"] > now() + 50 * 60_000

    # fresh now: no second refresh
    assert {:ok, %{token: "at-2"}} = Auth.access_token(:anthropic)
    refute_received {:refresh_request, _}
  end

  test "a login moved over without its access token refreshes on first use" do
    start_supervised!({Auth, respond: endpoint()})
    :ok = Auth.put(:openai_codex, creds(%{"access" => "", "expires" => 0}))

    assert {:ok, %{token: "at-2"}} = Auth.access_token(:openai_codex)

    assert_received {:refresh_request,
                     %{"grant_type" => "refresh_token", "refresh_token" => "rt-1"}}
  end

  test "concurrent callers share one refresh" do
    start_supervised!({Auth, respond: endpoint(200, 150)})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Auth.access_token(:anthropic) end) end)
      |> Task.await_many()

    assert Enum.uniq(results) == [{:ok, %{token: "at-2", account_id: nil}}]
    assert_received {:refresh_request, _}
    refute_received {:refresh_request, _}
  end

  test "a failed refresh is an error that keeps the sign-in, and is announced" do
    start_supervised!({Auth, respond: endpoint(400)})
    old = creds(%{"expires" => now()})
    :ok = Auth.put(:anthropic, old)
    :ok = Auth.subscribe()

    assert {:error, {:refresh_failed, message}} = Auth.access_token(:anthropic)
    assert message =~ "400 invalid_grant: Refresh token expired"
    assert_receive {:operator_auth, :changed}
    assert Auth.get(:anthropic) == {:ok, old}
  end

  test "a new sign-in during a refresh wins over the refresh's result" do
    start_supervised!({Auth, respond: endpoint(200, 200)})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

    waiting = Task.async(fn -> Auth.access_token(:anthropic) end)
    assert_receive {:refresh_request, _}

    fresh = creds(%{"access" => "at-new", "refresh" => "rt-new"})
    :ok = Auth.put(:anthropic, fresh)

    assert Task.await(waiting) == {:ok, %{token: "at-new", account_id: nil}}
    assert Auth.get(:anthropic) == {:ok, fresh}
  end

  describe "when the store fails" do
    setup do
      on_exit(&FlakySecureStore.restore/0)
    end

    test "a refreshed sign-in that can't be saved is never handed out nor refreshed again from the spent token" do
      start_supervised!({Auth, respond: endpoint(), save_retry_ms: 60_000})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))
      :ok = Auth.subscribe()
      FlakySecureStore.install([:put])

      assert Auth.access_token(:anthropic) == {:error, {:store_failed, :disk_full}}
      assert_received {:refresh_request, %{"refresh_token" => "rt-1"}}
      assert_received {:operator_auth, :changed}

      # the store still holds the spent rt-1: no second refresh with it
      assert Auth.access_token(:anthropic) == {:error, {:store_failed, :disk_full}}
      refute_received {:refresh_request, _}
      assert {:ok, %{"refresh" => "rt-1"}} = Auth.get(:anthropic)

      # saving works again: the next call saves the rotated sign-in, then hands it out
      FlakySecureStore.fail([])
      assert {:ok, %{token: "at-2"}} = Auth.access_token(:anthropic)
      refute_received {:refresh_request, _}
      assert {:ok, %{"access" => "at-2", "refresh" => "rt-2"}} = Auth.get(:anthropic)
    end

    test "an unsaved refreshed sign-in is saved by a background retry" do
      start_supervised!({Auth, respond: endpoint(), save_retry_ms: 20})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))
      FlakySecureStore.install([:put])

      assert {:error, {:store_failed, _}} = Auth.access_token(:anthropic)
      FlakySecureStore.fail([])
      Process.sleep(100)

      assert {:ok, %{"refresh" => "rt-2"}} = Auth.get(:anthropic)
    end

    test "a replacement that doesn't save leaves the refresh in flight in charge" do
      start_supervised!({Auth, respond: endpoint(200, 200)})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

      waiting = Task.async(fn -> Auth.access_token(:anthropic) end)
      assert_receive {:refresh_request, %{"refresh_token" => "rt-1"}}

      FlakySecureStore.install([:put])
      assert {:error, :disk_full} = Auth.put(:anthropic, creds(%{"refresh" => "rt-other"}))
      FlakySecureStore.fail([])

      # the refresh's rotated result is kept, not dropped and redone with the spent rt-1
      assert Task.await(waiting) == {:ok, %{token: "at-2", account_id: nil}}
      assert {:ok, %{"refresh" => "rt-2"}} = Auth.get(:anthropic)
      refute_received {:refresh_request, _}
    end

    test "a sign-out that doesn't delete is an error, and nothing changes" do
      start_supervised!(Auth)
      :ok = Auth.put(:anthropic, creds())
      :ok = Auth.subscribe()
      FlakySecureStore.install([:delete])

      assert Auth.delete(:anthropic) == {:error, :disk_full}
      refute_received {:operator_auth, :changed}
      assert Auth.signed_in?(:anthropic)
    end
  end
end
