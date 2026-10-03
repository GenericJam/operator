defmodule Operator.HandoffTest do
  use ExUnit.Case, async: true

  alias Operator.Handoff
  alias Operator.Handoff.Inbox

  @moduletag :tmp_dir

  @handoff %{
    title: "Ship the QR handoff",
    cwd: "/Users/kevin/code/operator",
    created: 1_790_762_400_000
  }
  @minute 60_000
  @t0 1_790_762_400_000

  # Incompressible text: the most codes a summary of this size can need.
  defp summary(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.encode64() |> binary_part(0, bytes)

  defp encode(bytes), do: Handoff.encode(Map.put(@handoff, :summary, summary(bytes)))

  defp parts(links) do
    for link <- links do
      {:ok, part} = Handoff.parse(link)
      part
    end
  end

  defp start_inbox(dir), do: start_supervised!({Inbox, name: nil, dir: dir}, id: make_ref())

  defp put(inbox, part, now \\ @t0), do: Inbox.put(part, server: inbox, now: now)

  test "a 20 kB summary: every link fits a 1200-character QR; parts arrive in any order, duplicates ignored",
       %{tmp_dir: dir} do
    summary = summary(20_000)
    links = Handoff.encode(Map.put(@handoff, :summary, summary))
    total = length(links)

    assert total > 2
    assert Enum.all?(links, &(byte_size(&1) <= 1200))
    assert Enum.all?(links, &String.starts_with?(&1, "operator://handoff?"))

    inbox = start_inbox(dir)
    [first | rest] = links |> parts() |> Enum.shuffle()
    {middle, [last]} = Enum.split(rest, -1)

    assert put(inbox, first) == {:partial, 1, total}
    assert put(inbox, first) == {:partial, 1, total}

    for {part, received} <- Enum.with_index(middle, 2),
        do: assert(put(inbox, part) == {:partial, received, total})

    assert put(inbox, last) == {:complete, Map.put(@handoff, :summary, summary)}
    # The set is gone: a part scanned again starts over.
    assert put(inbox, last) == {:partial, 1, total}
  end

  test "the same handoff gives the same links; another handoff's parts don't join its set",
       %{tmp_dir: dir} do
    summary = summary(3_000)
    a = Handoff.encode(Map.put(@handoff, :summary, summary))
    assert Handoff.encode(Map.put(@handoff, :summary, summary)) == a

    b = encode(3_000)
    inbox = start_inbox(dir)
    [a1, a2 | a_rest] = parts(a)
    [b1 | _] = parts(b)

    assert put(inbox, a1) == {:partial, 1, length(a)}
    assert put(inbox, b1) == {:partial, 1, length(b)}
    assert put(inbox, a2) == {:partial, 2, length(a)}

    results = for part <- a_rest, do: put(inbox, part)
    assert {:complete, %{summary: ^summary}} = List.last(results)
  end

  test "a damaged chunk fails the whole set, which is dropped", %{tmp_dir: dir} do
    [p1, p2 | rest] = encode(3_000) |> parts()
    <<head::binary-size(100), c, tail::binary>> = p2.data
    damaged = %{p2 | data: head <> if(c == ?A, do: "B", else: "A") <> tail}

    inbox = start_inbox(dir)
    for part <- [p1 | rest], do: put(inbox, part)

    assert put(inbox, damaged) == {:error, :corrupt}
    assert put(inbox, p1) == {:partial, 1, length(rest) + 2}
  end

  test "a set no part joined for 30 minutes is dropped", %{tmp_dir: dir} do
    [p1, p2, p3 | _] = parts = encode(3_000) |> parts()
    total = length(parts)
    inbox = start_inbox(dir)

    assert put(inbox, p1, @t0) == {:partial, 1, total}
    assert put(inbox, p2, @t0 + 30 * @minute) == {:partial, 2, total}
    # 30 minutes after the last part joined, not the first.
    assert put(inbox, p3, @t0 + 60 * @minute + 1) == {:partial, 1, total}
  end

  test "parts survive a restart", %{tmp_dir: dir} do
    [first | rest] = encode(3_000) |> parts()
    inbox = start_supervised!({Inbox, name: nil, dir: dir}, id: :before)
    assert {:partial, 1, _} = put(inbox, first)
    :ok = stop_supervised!(:before)

    inbox = start_inbox(dir)

    assert {:complete, %{title: "Ship the QR handoff"}} =
             rest |> Enum.map(&put(inbox, &1)) |> List.last()
  end

  test "a handoff from a newer format is refused as such", %{tmp_dir: dir} do
    deflated = :zlib.compress(Jason.encode!(%{"v" => 2, "summary" => "later"}))
    id = :sha256 |> :crypto.hash(deflated) |> binary_part(0, 4) |> Base.encode16(case: :lower)
    data = Base.url_encode64(deflated, padding: false)

    {:ok, part} = Handoff.parse("operator://handoff?id=#{id}&p=1&n=1&d=#{data}")
    assert put(start_inbox(dir), part) == {:error, :unsupported_version}
  end

  test "only well-formed handoff links parse" do
    [link] = encode(100)
    {:ok, %{id: id, index: 1, total: 1, data: data}} = Handoff.parse(link)
    base = "operator://handoff?id=#{id}"

    assert Handoff.parse("https://example.com/") == {:error, :not_handoff}
    assert Handoff.parse("operator://login?c=abc") == {:error, :not_handoff}

    for bad <- [
          "operator://handoff?id=XYZ&p=1&n=1&d=#{data}",
          "#{base}&p=2&n=1&d=#{data}",
          "#{base}&p=0&n=1&d=#{data}",
          "#{base}&p=1&n=100&d=#{data}",
          "#{base}&p=1&n=1&d=#{data}%21",
          "#{base}&p=1&n=1"
        ],
        do: assert(Handoff.parse(bad) == {:error, :bad_link}, bad)
  end
end
