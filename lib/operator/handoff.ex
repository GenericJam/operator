defmodule Operator.Handoff do
  @moduledoc """
  omp's handoff, carried from the Mac to the phone in QR codes.

  `/handoff` in omp writes a document for whoever picks the work up next,
  as a `compaction` entry with `method: "handoff"`. `mix operator.handoff`
  takes the latest one from the omp session and shows `encode/1`'s links,
  one QR each. Scanning one with any QR app opens Operator
  (`Operator.Links`); `Operator.Handoff.Inbox` collects the parts in any
  order, and the last one starts a session on the phone that opens with
  `framed/1`. The transcript itself doesn't travel: it assumes omp's tools
  (a shell, the Mac's files) the phone doesn't have.

  The payload is JSON `{"v": 1, "title", "cwd", "summary", "created"}`
  (`created` in ms since the epoch), zlib-deflated, base64url-encoded
  without padding and cut into chunks so that every link is at most 1200
  characters (a QR at error correction M a phone reads reliably off a
  laptop screen):

      operator://handoff?id=<8 hex>&p=<i>&n=<total>&d=<chunk>

  `id` is the first 4 bytes of the SHA-256 of the deflated payload, so two
  runs over the same handoff give the same links, and the joined chunks
  are checked against it. `p` counts from 1.

  Pure: no processes.
  """

  @prefix "operator://handoff?id="
  @max_link 1200
  @max_parts 99
  # Inflated payloads past this are refused: a crafted QR set mustn't
  # inflate into something the phone can't hold.
  @max_payload 2_000_000

  @type t :: %{
          title: String.t() | nil,
          cwd: String.t() | nil,
          summary: String.t(),
          created: integer() | nil
        }
  @type part :: %{id: String.t(), index: pos_integer(), total: pos_integer(), data: String.t()}
  @type reason :: :not_handoff | :bad_link | :mixed_parts | :corrupt | :unsupported_version

  @doc """
  The links for a handoff (`:summary`, plus optional `:title`, `:cwd` and
  `:created`, ms; default now), in order. Raises `ArgumentError` when it
  needs more than #{@max_parts} codes.
  """
  @spec encode(map()) :: [String.t()]
  def encode(%{summary: summary} = handoff) when is_binary(summary) do
    payload = %{
      "v" => 1,
      "title" => handoff[:title],
      "cwd" => handoff[:cwd],
      "summary" => summary,
      "created" => handoff[:created] || System.os_time(:millisecond)
    }

    deflated = :zlib.compress(Jason.encode!(payload))
    id = id(deflated)
    chunks = deflated |> Base.url_encode64(padding: false) |> chunks(1)
    total = length(chunks)

    if total > @max_parts,
      do: raise(ArgumentError, "the handoff needs #{total} QR codes; at most #{@max_parts} fit")

    for {chunk, i} <- Enum.with_index(chunks, 1),
        do: "#{@prefix}#{id}&p=#{i}&n=#{total}&d=#{chunk}"
  end

  @doc "Reads one link; `{:error, :not_handoff}` for anything that isn't a handoff link."
  @spec parse(String.t()) :: {:ok, part()} | {:error, :not_handoff | :bad_link}
  def parse(link) do
    case Operator.Links.params(link, "handoff") do
      {:ok, %{"id" => id, "p" => p, "n" => n, "d" => data}} ->
        with true <- id =~ ~r/\A[0-9a-f]{8}\z/,
             {index, ""} <- Integer.parse(p),
             {total, ""} <- Integer.parse(n),
             true <- index >= 1 and index <= total and total <= @max_parts,
             true <- byte_size(data) <= @max_link and data =~ ~r/\A[A-Za-z0-9_-]+\z/ do
          {:ok, %{id: id, index: index, total: total, data: data}}
        else
          _ -> {:error, :bad_link}
        end

      {:ok, _incomplete} ->
        {:error, :bad_link}

      :error ->
        {:error, :not_handoff}
    end
  end

  @doc """
  Joins a complete set's chunks (in part order) back into the handoff,
  checking them against the set's `id`.
  """
  @spec assemble(String.t(), [String.t()]) ::
          {:ok, t()} | {:error, :corrupt | :unsupported_version}
  def assemble(id, chunks) do
    with {:ok, deflated} <- Base.url_decode64(Enum.join(chunks), padding: false),
         ^id <- id(deflated),
         {:ok, json} <- inflate(deflated),
         {:ok, %{} = payload} <- Jason.decode(json) do
      decode(payload)
    else
      _ -> {:error, :corrupt}
    end
  end

  @doc """
  The first user message of the session a handoff starts on the phone: the
  handoff document, told it now runs on the phone.
  """
  @spec framed(t()) :: String.t()
  def framed(%{summary: summary} = handoff) do
    project = if handoff[:cwd] in [nil, ""], do: "", else: " (project #{handoff.cwd})"

    "Handoff from omp on the Mac#{project}. You are now Operator on the phone: no shell or " <>
      "Mac files; your tools are listed in your system prompt. Here is the handoff:\n\n" <>
      summary
  end

  @doc "A plain sentence for an error from `parse/1`, `Operator.Handoff.Inbox.put/2` or `assemble/2`."
  @spec message(reason()) :: String.t()
  def message(:not_handoff), do: "That QR isn't an Operator handoff."
  def message(:bad_link), do: "That handoff code didn't read right: scan it again."

  def message(:mixed_parts),
    do: "That code doesn't belong with the ones scanned so far: run mix operator.handoff again."

  def message(:corrupt),
    do: "That handoff didn't decode: run mix operator.handoff again and scan every code."

  def message(:unsupported_version),
    do: "That handoff comes from a newer Operator: update the app, then scan again."

  # ── internals ──

  defp id(deflated),
    do: :sha256 |> :crypto.hash(deflated) |> binary_part(0, 4) |> Base.encode16(case: :lower)

  # Each link: the prefix, the id, "&p=", "&n=", "&d=", the chunk, with p
  # as wide as n at most. A wider n than assumed takes another pass.
  defp chunks(data, digits) do
    size = @max_link - byte_size(@prefix) - 8 - byte_size("&p=&n=&d=") - 2 * digits
    total = max(div(byte_size(data) + size - 1, size), 1)

    if total >= Integer.pow(10, digits), do: chunks(data, digits + 1), else: split(data, size)
  end

  defp split(data, size) when byte_size(data) <= size, do: [data]

  defp split(data, size) do
    <<chunk::binary-size(^size), rest::binary>> = data
    [chunk | split(rest, size)]
  end

  defp decode(%{"v" => 1, "summary" => summary} = payload) when is_binary(summary) do
    {:ok,
     %{
       title: string(payload["title"]),
       cwd: string(payload["cwd"]),
       summary: summary,
       created: if(is_integer(payload["created"]), do: payload["created"])
     }}
  end

  defp decode(%{"v" => v}) when is_integer(v) and v > 1, do: {:error, :unsupported_version}
  defp decode(_payload), do: {:error, :corrupt}

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_), do: nil

  defp inflate(deflated) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflate(z, :zlib.safeInflate(z, deflated), [], 0)
    rescue
      ErlangError -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, out}, acc, size) when status in [:continue, :finished] do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_payload -> :error
      status == :finished -> {:ok, IO.iodata_to_binary([acc, out])}
      true -> inflate(z, :zlib.safeInflate(z, []), [acc, out], size)
    end
  end

  # {:need_dictionary, ...}: not a stream encode/1 made.
  defp inflate(_z, _other, _acc, _size), do: :error
end
