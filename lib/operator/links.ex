defmodule Operator.Links do
  @moduledoc """
  `operator://` links: what a QR made on the Mac holds, so that scanning it
  with any app (the phone's camera, a QR app, or Diagnostics → Scan QR)
  opens Operator.

    * `operator://login?c=…`: a login sealed by `mix operator.login`
      (`Operator.Auth.Transfer`); the six words are still typed on the phone.
    * `operator://handoff?id=…&p=…&n=…&d=…`: one part of omp's handoff, from
      `mix operator.handoff` (`Operator.Handoff`).
    * `operator://deliver?endpoint=…&key=…`: the Mac's update server, from
      `mix operator.deliver.qr` (`Operator.Deliver`).
    * `operator://cluster?…`: a short-lived TLS cluster invite
      (`Operator.Cluster.Invite`).

  A link the app is opened with (Android `MainActivity`, iOS `SceneDelegate`;
  the `operator` scheme is declared by `url_schemes` in `mob.exs`) reaches
  the screen showing as mob's `{:link, %{url: link}}` (`Mob.Link`), held
  until the root screen has mounted on a cold launch; that screen passes it
  to `handle/1`. Any app can open one, so `handle/1` checks it like any other
  input.
  """

  alias Operator.Auth.Transfer
  alias Operator.Cluster.Invite
  alias Operator.Core.Session
  alias Operator.Deliver
  alias Operator.Handoff
  alias Operator.Handoff.Inbox

  @type result ::
          {:login, String.t()}
          | {:handoff_part, pos_integer(), pos_integer()}
          | {:handoff, Handoff.t(), pid()}
          | {:deliver, String.t()}
          | {:cluster, Invite.t()}
          | {:error, String.t()}
  @doc """
  Acts on a scanned link:

    * a login link: `{:login, link}` for `Operator.LoginScanScreen`, which
      asks for the words;
    * a handoff part: kept in `Operator.Handoff.Inbox`, `{:handoff_part,
      received, total}` until the set is complete; the last part starts a
      new session that opens with the handoff (`Operator.Handoff.framed/1`
      as its first user message);
    * an update-server link: `{:deliver, endpoint}` when its address is
      usable and it is for this build's key (`Operator.Deliver.parse/1`);
      nothing is saved until the user confirms it in
      `Operator.LoginScanScreen`;
    * a cluster invite: `{:cluster, invite}` after its syntax and bounds
      have been checked; joining still requires the system screen lock;
    * anything else: `{:error, sentence}` to show.
  """
  @spec handle(String.t()) :: result()
  def handle(link) when is_binary(link) do
    case Invite.parse(link) do
      {:ok, invite} -> {:cluster, invite}
      {:error, message} -> {:error, message}
      :not_cluster -> deliver_or_other(link)
    end
  end

  defp deliver_or_other(link) do
    case params(link, "deliver") do
      {:ok, params} -> deliver(Deliver.parse(params))
      :error -> handoff_or_login(link)
    end
  end

  defp handoff_or_login(link) do
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

  defp deliver({:ok, endpoint}), do: {:deliver, endpoint}
  defp deliver({:error, _sentence} = refused), do: refused

  defp login(link) do
    case Transfer.check(link) do
      :ok -> {:login, link}
      {:error, :not_operator_code} -> {:error, "That QR isn't an Operator code."}
      {:error, reason} -> {:error, Transfer.message(reason)}
    end
  end
end
