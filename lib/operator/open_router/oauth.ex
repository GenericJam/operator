defmodule Operator.OpenRouter.OAuth do
  @moduledoc """
  "Sign in with OpenRouter" (OAuth PKCE, S256), run entirely on the phone.

  Two variants share one verifier:

    * **localhost callback** (preferred): a tiny `:gen_tcp` listener on
      `127.0.0.1:<port>` in this BEAM. The phone's browser is redirected to
      `http://localhost:<port>/callback?code=…&state=…`, which this process
      answers and exchanges. OpenRouter accepts localhost callbacks on any
      port.
    * **headless**: the same flow without `callback_url`; OpenRouter shows the
      code on its page and the user pastes it into the app
      (`exchange_pasted/1`).

  The exchange (`POST /api/v1/auth/keys`) returns a user-controlled key,
  stored with `Operator.KeyStore`. It runs in a task and retries transport
  errors every 2 s for up to 9 minutes: Android 15 blocks a backgrounded
  app's outbound network (~60 s after it leaves the foreground), so the
  exchange completes when the user switches back from the browser. State
  lives in this GenServer; observers get `status/0`, never the key.
  """
  use GenServer
  require Logger

  @auth_url "https://openrouter.ai/auth"
  @keys_url "https://openrouter.ai/api/v1/auth/keys"
  @port 51_423

  # ── API ──

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts a flow, opens the browser, returns the URL that was opened."
  @spec begin(:localhost | :headless) :: {:ok, String.t()} | {:error, term()}
  def begin(mode \\ :localhost), do: GenServer.call(__MODULE__, {:begin, mode})

  @doc "Starts the exchange of a code the user pasted (headless variant); watch `status/0`."
  @spec exchange_pasted(String.t()) :: :ok | {:error, :no_flow_started}
  def exchange_pasted(code), do: GenServer.call(__MODULE__, {:pasted, String.trim(code)})

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Subscribe the caller to `{:oauth, status}` messages."
  def subscribe, do: GenServer.cast(__MODULE__, {:subscribe, self()})

  # ── PKCE helpers (pure) ──

  @spec new_verifier() :: String.t()
  def new_verifier, do: :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)

  @spec challenge(String.t()) :: String.t()
  def challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  @spec auth_url(String.t(), :localhost | :headless, String.t()) :: String.t()
  def auth_url(verifier, mode, state) do
    base = %{
      "code_challenge" => challenge(verifier),
      "code_challenge_method" => "S256",
      "key_label" => "Operator (phone)"
    }

    params =
      case mode do
        :localhost -> Map.merge(base, %{"callback_url" => callback_url(), "state" => state})
        :headless -> base
      end

    @auth_url <> "?" <> URI.encode_query(params)
  end

  def callback_url, do: "http://localhost:#{@port}/callback"

  # ── GenServer ──

  @impl true
  def init(:ok) do
    {:ok,
     %{
       phase: if(Operator.KeyStore.present?(), do: :signed_in, else: :signed_out),
       mode: nil,
       verifier: nil,
       state: nil,
       listen: nil,
       error: nil,
       started_at: nil,
       exchange_ms: nil,
       code: nil,
       code_at: nil,
       attempts: 0,
       task: nil,
       subscribers: []
     }}
  end

  @impl true
  def handle_call({:begin, mode}, _from, s) do
    s = close_listener(s)
    verifier = new_verifier()
    state = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    case maybe_listen(%{s | verifier: verifier, state: state, mode: mode, code: nil}) do
      {:ok, s} ->
        url = auth_url(verifier, mode, state)
        :ok = Mob.Device.open_url(url)
        s = notify(%{s | phase: :awaiting_browser, error: nil, started_at: now()})
        {:reply, {:ok, url}, s}

      {:error, reason} = err ->
        {:reply, err, notify(%{s | phase: :failed, error: reason})}
    end
  end

  def handle_call({:pasted, _code}, _from, %{verifier: nil} = s),
    do: {:reply, {:error, :no_flow_started}, s}

  def handle_call({:pasted, code}, _from, s),
    do: {:reply, :ok, start_exchange(code, s)}

  def handle_call(:status, _from, s) do
    {:reply,
     %{
       phase: s.phase,
       mode: s.mode,
       error: s.error,
       listening: s.listen != nil,
       key_present: Operator.KeyStore.present?(),
       key_fingerprint: Operator.KeyStore.fingerprint(),
       exchange_ms: s.exchange_ms,
       exchange_attempts: s.attempts,
       callback_url: callback_url()
     }, s}
  end

  # The acceptor hands over the callback's query string. The exchange runs
  # asynchronously: while the browser is in front, Android can block this
  # app's outbound network (seen on the API 35 emulator: connect timeouts
  # until Operator is foregrounded again), so it retries until the user
  # switches back, within the code's 10-minute lifetime.
  def handle_call({:callback, query}, _from, s) do
    params = URI.decode_query(query)

    cond do
      params["state"] != s.state ->
        {:reply, :failed, close_listener(notify(%{s | phase: :failed, error: :state_mismatch}))}

      is_binary(params["code"]) ->
        {:reply, :received, close_listener(start_exchange(params["code"], s))}

      true ->
        s = notify(%{s | phase: :failed, error: {:callback, Map.drop(params, ["code"])}})
        {:reply, :failed, close_listener(s)}
    end
  end

  @impl true
  def handle_cast({:subscribe, pid}, s), do: {:noreply, %{s | subscribers: [pid | s.subscribers]}}

  @impl true
  def handle_info(:retry_exchange, %{code: code} = s) when is_binary(code),
    do: {:noreply, run_exchange(s)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_exchange(result, %{s | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = s),
    do: {:noreply, finish_exchange({:error, {:crashed, reason}}, %{s | task: nil})}

  def handle_info(_msg, s), do: {:noreply, s}

  # ── internals ──

  defp maybe_listen(%{mode: :headless} = s), do: {:ok, s}

  defp maybe_listen(s) do
    opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

    case :gen_tcp.listen(@port, opts) do
      {:ok, sock} ->
        owner = self()
        {:ok, _} = Task.start(fn -> accept_loop(sock, owner) end)
        {:ok, %{s | listen: sock}}

      {:error, reason} ->
        {:error, {:listen, reason}}
    end
  end

  defp accept_loop(sock, owner) do
    case :gen_tcp.accept(sock) do
      {:ok, conn} ->
        handle_conn(conn, owner)
        accept_loop(sock, owner)

      {:error, _closed} ->
        :ok
    end
  end

  # Minimal HTTP/1.1: read the request line, answer one page, close.
  # Browsers also ask for /favicon.ico; anything but /callback gets a 404.
  defp handle_conn(conn, owner) do
    with {:ok, data} <- recv_head(conn, ""),
         ["GET " <> rest | _] <- String.split(data, "\r\n"),
         [target | _] <- String.split(rest, " "),
         %URI{path: "/callback", query: query} <- URI.parse(target) do
      case GenServer.call(owner, {:callback, query || ""}, 10_000) do
        :received ->
          reply(
            conn,
            200,
            "<h2>Code received.</h2><p>Switch back to Operator to finish signing in.</p>"
          )

        _ ->
          reply(conn, 200, "<h2>Sign-in failed.</h2><p>Return to Operator; it shows why.</p>")
      end
    else
      _ -> reply(conn, 404, "not found")
    end

    :gen_tcp.close(conn)
  end

  defp recv_head(conn, acc) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: recv_head(conn, acc)

      {:error, _} = err ->
        err
    end
  end

  defp reply(conn, code, body) do
    html = "<!doctype html><meta name=viewport content='width=device-width'>" <> body

    :gen_tcp.send(conn, [
      "HTTP/1.1 #{code} #{if code == 200, do: "OK", else: "Not Found"}\r\n",
      "content-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(html)}\r\n",
      "connection: close\r\n\r\n",
      html
    ])
  end

  # Codes expire 10 minutes after issue; stop retrying a bit before that.
  @code_lifetime_ms 9 * 60_000
  @retry_ms 2_000

  defp start_exchange(code, s) do
    run_exchange(%{s | code: code, code_at: now(), attempts: 0, error: nil})
  end

  defp run_exchange(%{task: %Task{}} = s), do: s

  defp run_exchange(s) do
    verifier = s.verifier
    code = s.code
    task = Task.async(fn -> exchange_request(code, verifier) end)
    notify(%{s | phase: :exchanging, task: task, attempts: s.attempts + 1})
  end

  defp exchange_request(code, verifier) do
    t0 = now()

    result =
      Req.post(@keys_url,
        json: %{code: code, code_verifier: verifier, code_challenge_method: "S256"},
        retry: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 20_000
      )

    ms = now() - t0

    case result do
      {:ok, %{status: 200, body: %{"key" => key}}} when is_binary(key) -> {:ok, key, ms}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, scrub(body)}}
      {:error, e} -> {:retry, {:transport, Exception.message(e)}}
    end
  end

  defp finish_exchange({:ok, key, ms}, s) do
    case Operator.KeyStore.put(key) do
      :ok ->
        Logger.info("[oauth] signed in (#{ms} ms exchange, attempt #{s.attempts})")

        notify(%{
          s
          | phase: :signed_in,
            error: nil,
            exchange_ms: ms,
            verifier: nil,
            state: nil,
            code: nil
        })

      # The code is spent: signing in again starts a new flow.
      {:error, reason} ->
        Logger.error("[oauth] storing the key failed: #{inspect(reason)}")
        notify(%{s | phase: :failed, error: {:key_store, reason}, code: nil})
    end
  end

  defp finish_exchange({:retry, reason}, s) do
    if now() - s.code_at < @code_lifetime_ms do
      Process.send_after(self(), :retry_exchange, @retry_ms)
      notify(%{s | phase: :waiting_for_network, error: reason})
    else
      notify(%{s | phase: :failed, error: {:code_expired, reason}, code: nil})
    end
  end

  defp finish_exchange({:error, reason}, s),
    do: notify(%{s | phase: :failed, error: reason, code: nil})

  # The error body never contains a key, but keep it bounded for the UI.
  defp scrub(body) when is_map(body), do: Map.take(body, ["error", "message"])
  defp scrub(body), do: body |> inspect() |> binary_part(0, min(200, byte_size(inspect(body))))

  defp close_listener(%{listen: nil} = s), do: s

  defp close_listener(%{listen: sock} = s) do
    :gen_tcp.close(sock)
    %{s | listen: nil}
  end

  defp notify(s) do
    Enum.each(s.subscribers, &send(&1, {:oauth, s.phase}))
    s
  end

  defp now, do: System.monotonic_time(:millisecond)
end
