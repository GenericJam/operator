defmodule Operator.Links do
  @moduledoc """
  `operator://` links: what a QR made on the Mac holds, so that scanning it
  with any app (the phone's camera, a QR app, or Diagnostics → Scan QR)
  opens Operator.

    * `operator://login?c=…`: a login sealed by `mix operator.login`
      (`Operator.Auth.Transfer`); the six words are still typed on the phone.
    * `operator://handoff?id=…&p=…&n=…&d=…`: one part of omp's handoff, from
      `mix operator.handoff` (`Operator.Handoff`).

  On Android, `MainActivity` hands a link it is opened with to mob as a
  notification tap (mob has no deep-link API), so it reaches the screen
  showing as `{:notification, %{data: %{operator_link: link}}}`; that
  screen passes it to `handle/1`.
  """

  alias Operator.Auth.Transfer
  alias Operator.Core.Session
  alias Operator.Handoff
  alias Operator.Handoff.Inbox

  @type result ::
          {:login, String.t()}
          | {:handoff_part, pos_integer(), pos_integer()}
          | {:handoff, Handoff.t(), pid()}
          | {:error, String.t()}

  @doc """
  Acts on a scanned link:

    * a login link: `{:login, link}` for `Operator.LoginScanScreen`, which
      asks for the words;
    * a handoff part: kept in `Operator.Handoff.Inbox`, `{:handoff_part,
      received, total}` until the set is complete; the last part starts a
      new session that opens with the handoff (`Operator.Handoff.framed/1`
      as its first user message, sent with the next prompt; nothing goes to
      the model before that) and returns `{:handoff, handoff, loop}`;
    * anything else: `{:error, sentence}` to show.
  """
  @spec handle(String.t()) :: result()
  def handle(link) when is_binary(link) do
    case Handoff.parse(link) do
      {:ok, part} -> handoff(part)
      {:error, :not_handoff} -> login(link)
      {:error, reason} -> {:error, Handoff.message(reason)}
    end
  end

  @doc """
  The query parameters of an `operator://<host>?…` link, or `:error` when
  `text` isn't one.
  """
  @spec params(String.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | :error
  def params(text, host) when is_binary(text) do
    case URI.parse(text) do
      %URI{scheme: "operator", host: ^host, query: query} when is_binary(query) ->
        {:ok, URI.decode_query(query)}

      _ ->
        :error
    end
  end

  defp handoff(part) do
    case Inbox.put(part) do
      {:partial, received, total} ->
        {:handoff_part, received, total}

      {:complete, handoff} ->
        entry = Session.user(Handoff.framed(handoff))
        {:handoff, handoff, Operator.Core.new_session_with(entry, title: handoff.title)}

      {:error, reason} ->
        {:error, Handoff.message(reason)}
    end
  end

  defp login(link) do
    case Transfer.check(link) do
      :ok -> {:login, link}
      {:error, :not_operator_code} -> {:error, "That QR isn't an Operator code."}
      {:error, reason} -> {:error, Transfer.message(reason)}
    end
  end
end
