defmodule Operator.Core.Tools.HttpGet do
  @moduledoc """
  Core tool: GET a web page or API over http(s) and return its status,
  content type and body as text (the output budget cuts long bodies into
  an artifact). Uses the app's CA store (`Operator.Certs`).

  Only `http` and `https` URLs; bodies over 2 MB and non-text content
  types are refused rather than returned as bytes.
  """
  @behaviour Operator.Core.Tool

  @max_body 2_000_000
  @text_types ~w(text/ application/json application/xml application/javascript application/rss application/atom +json +xml)

  @impl true
  def name, do: "http_get"

  @impl true
  def description do
    "Fetch a URL with HTTP GET and return the status, content type and body text " <>
      "(web pages come back as HTML). Only http/https; text responses up to 2 MB."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "http:// or https:// URL"},
        "headers" => %{
          "type" => "object",
          "description" => "Extra request headers, name to value.",
          "additionalProperties" => %{"type" => "string"}
        }
      },
      "required" => ["url"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 30_000

  @impl true
  # `ctx[:respond]` (tests and the selftest) answers the request instead of
  # the network: `fn %Req.Request{} -> %Req.Response{} end`.
  def run(%{"url" => url} = args, ctx) when is_binary(url) do
    with {:ok, uri} <- check_url(url),
         {:ok, headers} <- check_headers(args["headers"] || %{}) do
      fetch(URI.to_string(uri), headers, Map.get(ctx, :respond))
    end
  end

  def run(_args, _ctx), do: {:error, "http_get needs a `url`"}

  defp check_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, "not an http(s) URL: #{inspect(url)}"}
    end
  end

  defp check_headers(headers) when is_map(headers) do
    if Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, Map.to_list(headers)},
      else: {:error, "headers must map names to strings"}
  end

  defp check_headers(_), do: {:error, "headers must be an object"}

  defp fetch(url, headers, respond) do
    req =
      Req.new(
        url: url,
        headers: [{"user-agent", "Operator (phone agent)"} | headers],
        redirect: true,
        max_redirects: 5,
        retry: false,
        decode_body: false,
        receive_timeout: 20_000,
        connect_options: [timeout: 10_000]
      )

    req =
      if respond,
        do: Req.Request.prepend_request_steps(req, respond: &{&1, respond.(&1)}),
        else: req

    case Req.request(req) do
      {:ok, %Req.Response{} = resp} -> describe(url, resp)
      {:error, e} -> {:error, "GET #{url} failed: #{Exception.message(e)}"}
    end
  end

  defp describe(url, resp) do
    type = resp |> Req.Response.get_header("content-type") |> List.first() || ""
    body = IO.iodata_to_binary(resp.body || "")

    cond do
      byte_size(body) > @max_body ->
        {:error, "GET #{url}: #{resp.status}, body is #{byte_size(body)} bytes (over 2 MB)"}

      not text?(type, body) ->
        {:error, "GET #{url}: #{resp.status}, #{type} (#{byte_size(body)} bytes) is not text"}

      true ->
        result = "HTTP #{resp.status} #{type}\n\n#{body}"
        if resp.status in 200..399, do: {:ok, result}, else: {:error, result}
    end
  end

  # By content type, or (none given) by whether the bytes are UTF-8.
  defp text?("", body), do: String.valid?(body)

  defp text?(type, _body),
    do: Enum.any?(@text_types, &String.contains?(String.downcase(type), &1))

  @impl true
  def selftest do
    respond = fn _req ->
      Req.Response.new(status: 200, headers: %{"content-type" => ["text/plain"]}, body: "ok")
    end

    case run(%{"url" => "https://example.invalid/"}, %{respond: respond}) do
      {:ok, "HTTP 200 text/plain\n\nok"} -> :ok
      other -> {:error, "selftest: #{inspect(other)}"}
    end
  end
end
