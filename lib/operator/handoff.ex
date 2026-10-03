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

  Limits, the same on both sides (`check/1`): the summary is at most 2,000
  lines and 64,000 bytes, since the chat draws every line of it as a row,
  and a few hundred bytes of QR can deflate into a million lines; the
  title and the project path are one line each, clipped to 200 and 1,000
  bytes. `encode/1` refuses a handoff the phone would refuse, and the
  phone stops inflating past what such a handoff can take.

  Pure: no processes.
  """

  @prefix "operator://handoff?id="
  @max_link 1200
  @max_parts 99
  @max_summary_lines 2_000
  @max_summary_bytes 64_000
  @max_title 200
  @max_cwd 1_000
  # The largest JSON a handoff within the limits encodes to (JSON escapes a
  # control character in 6 bytes), with room to spare. The phone stops
  # inflating past it.
  @max_payload 512_000

  @type t :: %{
          title: String.t() | nil,
          cwd: String.t() | nil,
          summary: String.t(),
          created: integer() | nil
        }
  @type part :: %{id: String.t(), index: pos_integer(), total: pos_integer(), data: String.t()}
  @type reason :: :not_handoff | :bad_link | :corrupt | :too_large | :unsupported_version

  @doc """
  The links for a handoff (`:summary`, plus optional `:title`, `:cwd` and
  `:created`, ms; default now), in order. Raises `ArgumentError` for a
  handoff the phone won't take (`check/1`), or one that needs more than
  #{@max_parts} codes.
  """
  @spec encode(map()) :: [String.t()]
  def encode(%{summary: summary} = handoff) when is_binary(summary) do
    if check(handoff) != :ok, do: raise(ArgumentError, message(:too_large))

    json =
      Jason.encode!(%{
        "v" => 1,
        "title" => line(handoff[:title], @max_title),
        "cwd" => line(handoff[:cwd], @max_cwd),
        "summary" => summary,
        "created" => handoff[:created] || System.os_time(:millisecond)
      })

    if byte_size(json) > @max_payload, do: raise(ArgumentError, message(:too_large))

    deflated = :zlib.compress(json)
    id = id(deflated)
    chunks = deflated |> Base.url_encode64(padding: false) |> chunks(1)
    total = length(chunks)

    if total > @max_parts,
      do: raise(ArgumentError, "the handoff needs #{total} QR codes; at most #{@max_parts} fit")

    for {chunk, i} <- Enum.with_index(chunks, 1),
        do: "#{@prefix}#{id}&p=#{i}&n=#{total}&d=#{chunk}"
  end

  @doc """
  Whether the phone takes a handoff: its summary is at most
  #{@max_summary_lines} lines and #{@max_summary_bytes} bytes.
  """
  @spec check(map()) :: :ok | {:error, :too_large}
  def check(%{summary: summary}) when is_binary(summary) do
    if byte_size(summary) <= @max_summary_bytes and
         length(:binary.matches(summary, "\n")) < @max_summary_lines,
       do: :ok,
       else: {:error, :too_large}
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
  checking them against the set's `id`, and the handoff against `check/1`.
  """
  @spec assemble(String.t(), [String.t()]) ::
          {:ok, t()} | {:error, :corrupt | :too_large | :unsupported_version}
  def assemble(id, chunks) do
    with {:ok, deflated} <- Base.url_decode64(Enum.join(chunks), padding: false),
         ^id <- id(deflated),
         {:ok, json} <- inflate(deflated),
         {:ok, %{} = payload} <- Jason.decode(json) do
      decode(payload)
    else
      {:error, :too_large} = error -> error
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

  def message(:corrupt),
    do: "That handoff didn't decode: scan every code again."

  def message(:too_large),
    do:
      "That handoff is too long for the phone (at most 2,000 lines and 64 kB): " <>
        "run /handoff in omp again with a narrower focus."

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
    handoff = %{
      title: line(payload["title"], @max_title),
      cwd: line(payload["cwd"], @max_cwd),
      summary: summary,
      created: if(is_integer(payload["created"]), do: payload["created"])
    }

    with :ok <- check(handoff), do: {:ok, handoff}
  end

  defp decode(%{"v" => v}) when is_integer(v) and v > 1, do: {:error, :unsupported_version}
  defp decode(_payload), do: {:error, :corrupt}

  # The first line, at most `max` bytes (cut at a character boundary); nil
  # for nothing.
  defp line(s, max) when is_binary(s) do
    case s |> String.split(["\r\n", "\n", "\r"], parts: 2) |> hd() |> cut(max) do
      "" -> nil
      line -> line
    end
  end

  defp line(_s, _max), do: nil

  defp cut(s, max) when byte_size(s) <= max, do: s

  defp cut(s, max) do
    part = binary_part(s, 0, max)
    if String.valid?(part), do: part, else: cut(part, max - 1)
  end

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
      size > @max_payload -> {:error, :too_large}
      status == :finished -> {:ok, IO.iodata_to_binary([acc, out])}
      true -> inflate(z, :zlib.safeInflate(z, []), [acc, out], size)
    end
  end

  # {:need_dictionary, ...}: not a stream encode/1 made.
  defp inflate(_z, _other, _acc, _size), do: :error
end
