defmodule Mix.Tasks.Operator.Login do
  @shortdoc "Signs in to Anthropic or OpenAI and shows the login as a QR for the phone"
  @moduledoc """
  Mints a fresh login on the Mac and hands it to the phone:

      mix operator.login anthropic   # Claude Pro/Max
      mix operator.login openai      # ChatGPT Plus/Pro (Codex)

  Runs the provider's OAuth sign-in in the Mac's browser (the URL is also
  printed), receives the redirect on the provider's localhost port (54545
  for Anthropic, 1455 for OpenAI), exchanges the code, and prints the login
  sealed by `Operator.Auth.Transfer` as a QR plus six words. When the
  provider shows a code page instead of redirecting, paste what it shows
  (`code#state`, the code, or the redirect URL) into the terminal. On the
  phone: scan the QR with the camera or any QR app (it opens Operator), or
  with Diagnostics → Scan QR, then type the words; the code works for 10
  minutes.

  Every run is a new grant, so the phone never shares a rotating refresh
  token with omp's own login. If omp's `/login` is running it holds the same
  port: finish or cancel it first.

  Doesn't start the Operator application, only loads its config.
  """
  use Mix.Task

  alias Mix.Operator.QR
  alias Operator.Auth.Login, as: AuthLogin
  alias Operator.Auth.OAuthFlow
  alias Operator.Auth.Transfer

  @wait_ms 10 * 60_000
  @providers %{
    "anthropic" => :anthropic,
    "openai" => :openai_codex,
    "openai-codex" => :openai_codex,
    "openai_codex" => :openai_codex
  }

  @impl Mix.Task
  def run(args) do
    provider =
      case args do
        [name] when is_map_key(@providers, name) -> Map.fetch!(@providers, name)
        _ -> Mix.raise("Usage: mix operator.login anthropic|openai")
      end

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    redirect = OAuthFlow.default_redirect(provider)
    %URI{port: port, path: path} = URI.parse(redirect)
    listeners = listen!(port)
    flow = OAuthFlow.start(provider, redirect)

    Mix.shell().info("""
    Sign in in your browser. If it didn't open, visit:

    #{flow.url}

    If the browser shows a code instead, paste it here and press Enter.
    """)

    open_browser(flow.url)
    stdin = start_stdin_reader()

    code =
      try do
        await_code(path, flow.state, System.monotonic_time(:millisecond) + @wait_ms)
      after
        Enum.each(listeners, &:gen_tcp.close/1)
      end

    creds =
      case OAuthFlow.exchange(provider, code, Map.take(flow, [:verifier, :state]), redirect) do
        {:ok, creds} -> creds
        {:error, message} -> Mix.raise("Sign-in failed: #{message}")
      end

    {qr, words} = Transfer.seal(provider, creds)
    flush_stdin()
    QR.print(qr)

    Mix.shell().info("""

    Words: #{words}

    On the phone: scan this code with the camera (or Diagnostics → Scan QR),
    then type the six words. The code works for 10 minutes. Press Enter here
    when done.
    """)

    await_enter(stdin)
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
  end

  # ── the terminal ──

  # One reader owns stdin for the whole run, so a pasted code can race the
  # browser's redirect and the final Enter isn't read twice. It stops at EOF
  # (stdin not a terminal); its :DOWN then ends the final wait.
  defp start_stdin_reader do
    parent = self()
    spawn_monitor(fn -> read_lines(parent) end)
  end

  defp read_lines(parent) do
    case IO.gets("") do
      line when is_binary(line) ->
        send(parent, {:stdin, line})
        read_lines(parent)

      _eof_or_error ->
        :ok
    end
  end

  # Lines typed while the code was being exchanged aren't the final Enter.
  defp flush_stdin do
    receive do
      {:stdin, _line} -> flush_stdin()
    after
      0 -> :ok
    end
  end

  defp await_enter({_pid, ref}) do
    receive do
      {:stdin, _line} -> :ok
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  # ── the redirect listener ──

  # A browser resolves `localhost` to 127.0.0.1 and ::1, so listen on both,
  # as omp does. A connect probe catches a listener we could otherwise bind
  # next to (a wildcard socket next to our specific one).
  defp listen!(port) do
    if Enum.any?([{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}], &taken?(&1, port)), do: busy!(port)

    opts = [:binary, packet: :raw, active: false, reuseaddr: true]

    v4 =
      case :gen_tcp.listen(port, [ip: {127, 0, 0, 1}] ++ opts) do
        {:ok, sock} -> sock
        {:error, :eaddrinuse} -> busy!(port)
        {:error, reason} -> Mix.raise("Can't listen on 127.0.0.1:#{port}: #{inspect(reason)}")
      end

    # No IPv6 loopback on this Mac: the IPv4 listener serves alone.
    v6 =
      case :gen_tcp.listen(port, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}] ++ opts) do
        {:ok, sock} -> [sock]
        {:error, :eaddrinuse} -> busy!(port)
        {:error, _unavailable} -> []
      end

    parent = self()
    for sock <- [v4 | v6], do: spawn_link(fn -> accept_loop(sock, parent) end)
    [v4 | v6]
  end

  defp taken?(ip, port) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], 300) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp busy!(port) do
    Mix.raise(
      "Port #{port} is in use, so the browser's redirect can't reach this task. " <>
        "Is omp's /login (or another mix operator.login) running? Finish or cancel it and retry."
    )
  end

  defp accept_loop(sock, parent) do
    case :gen_tcp.accept(sock) do
      {:ok, conn} ->
        serve(conn, parent)
        accept_loop(sock, parent)

      {:error, _closed} ->
        :ok
    end
  end

  # Minimal HTTP/1.1: read the request line, hand the query to the task,
  # answer one page, close. Anything that isn't a GET gets a 404.
  defp serve(conn, parent) do
    with {:ok, head} <- recv_head(conn, ""),
         ["GET " <> rest | _] <- String.split(head, "\r\n"),
         [target | _] <- String.split(rest, " ") do
      %URI{path: path, query: query} = URI.parse(target)
      ref = make_ref()
      send(parent, {:redirect, self(), ref, path, URI.decode_query(query || "")})

      receive do
        {^ref, status, text} -> reply(conn, status, text)
      after
        10_000 -> reply(conn, 500, "No answer from mix operator.login.")
      end
    else
      _ -> reply(conn, 404, "Not found.")
    end

    :gen_tcp.close(conn)
  end

  @doc false
  # The authorization code from whichever comes first: the browser's
  # redirect to `path` (`{:redirect, ...}` from the listener) or a line
  # pasted into the terminal (`{:stdin, line}`). Anything carrying another
  # sign-in's state, an error included, is turned away and the wait goes on,
  # as omp's callback server does, so a stale tab can't end this login.
  @spec await_code(String.t(), String.t(), integer()) :: String.t()
  def await_code(path, state, deadline) do
    receive do
      {:redirect, pid, ref, ^path, params} ->
        case params do
          %{"state" => ^state, "code" => code} when is_binary(code) and code != "" ->
            send(pid, {ref, 200, "Signed in. Go back to the terminal for the QR code."})
            code

          %{"state" => ^state, "error" => error} ->
            send(pid, {ref, 400, "Sign-in failed: #{error}. See the terminal."})
            Mix.raise("Sign-in failed: #{error} #{params["error_description"]}")

          _other ->
            send(pid, {ref, 400, "This page belongs to another sign-in. Use the newest tab."})
            await_code(path, state, deadline)
        end

      {:redirect, pid, ref, _other_path, _params} ->
        send(pid, {ref, 404, "Not found."})
        await_code(path, state, deadline)

      {:stdin, line} ->
        case pasted(line, state) do
          {:ok, code} -> code
          :skip -> await_code(path, state, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Mix.raise("No sign-in within 10 minutes. Run mix operator.login again.")
    end
  end

  # A bare code carries no state to check (omp's parseCallbackInput takes it
  # too); an empty line is just Enter.
  defp pasted(line, state) do
    case AuthLogin.parse_input(line) do
      {nil, nil} ->
        :skip

      {nil, _state} ->
        Mix.shell().info("No code in that. Paste what the browser shows (code#state).")
        :skip

      {code, pasted_state} when pasted_state in [nil, state] ->
        {:ok, code}

      {_code, _other} ->
        Mix.shell().info("That code belongs to another sign-in. Paste the newest one.")
        :skip
    end
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

  defp reply(conn, status, text) do
    html =
      "<!doctype html><meta charset=utf-8><title>Operator</title>" <>
        "<p style='font:16px system-ui;margin:2em'>#{text}</p>"

    reason = %{200 => "OK", 400 => "Bad Request", 404 => "Not Found", 500 => "Error"}[status]

    :gen_tcp.send(conn, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(html)}\r\n",
      "connection: close\r\n\r\n",
      html
    ])
  end

  # ── output ──

  defp open_browser(url) do
    if match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])
  end
end
