defmodule Operator.Cluster.Invite do
  @moduledoc """
  The pairing link a cluster node shows as a QR:

      operator://cluster?v=1&node=<name@address>&fp=<sha256 hex>&cookie=<cookie>&port=9370

  `node` is where to reach it, `fp` the fingerprint of the certificate it
  will present (pinned by whoever accepts the invite), `cookie` the
  cluster's distribution cookie (the secret: a photo of the QR is enough to
  join while the inviter's pairing window is open) and `port` the fixed
  distribution port every node of the cluster listens on.

  Phones show one from [menu] › cluster › pair; `mix operator.cluster.peer`
  prints one for a node that isn't a phone. Parsing never creates atoms:
  the node stays a string until the human has confirmed.
  """

  @type t :: %{node: String.t(), fingerprint: String.t(), cookie: String.t(), port: pos_integer()}

  @node ~r/\A[a-z][a-z0-9_]{0,62}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/
  @fingerprint ~r/\A[0-9a-f]{64}\z/
  @cookie ~r/\A[A-Za-z0-9_-]{16,128}\z/

  @doc "The link for `invite`."
  @spec link(t()) :: String.t()
  def link(%{node: node, fingerprint: fp, cookie: cookie, port: port}) do
    query = URI.encode_query(v: 1, node: node, fp: fp, cookie: cookie, port: port)
    "operator://cluster?" <> query
  end

  @doc "Reads and checks a link; `{:error, sentence}` says what's wrong with it."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()} | :not_cluster
  def parse(text) when is_binary(text) do
    case Operator.Links.params(String.trim(text), "cluster") do
      {:ok, params} -> check(params)
      :error -> :not_cluster
    end
  end

  defp check(%{"v" => "1", "node" => node, "fp" => fp, "cookie" => cookie, "port" => port}) do
    cond do
      not Regex.match?(@node, node) -> {:error, "That cluster code has a bad node name."}
      not Regex.match?(@fingerprint, fp) -> {:error, "That cluster code has a bad fingerprint."}
      not Regex.match?(@cookie, cookie) -> {:error, "That cluster code has a bad cookie."}
      true -> port(node, fp, cookie, Integer.parse(port))
    end
  end

  defp check(%{"v" => v}) when v != "1",
    do: {:error, "That cluster code is from a newer Operator: update this one."}

  defp check(_params), do: {:error, "That cluster code is incomplete."}

  defp port(node, fp, cookie, {port, ""}) when port in 1..65_535,
    do: {:ok, %{node: node, fingerprint: fp, cookie: cookie, port: port}}

  defp port(_node, _fp, _cookie, _bad), do: {:error, "That cluster code has a bad port."}
end
