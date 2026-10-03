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

  setup do
    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    %{clock: clock}
  end

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

  # A set of parts made by hand, as anyone's QR codes could carry, past
  # encode/1's checks.
  defp crafted(json) do
    deflated = :zlib.compress(json)
    id = :sha256 |> :crypto.hash(deflated) |> binary_part(0, 4) |> Base.encode16(case: :lower)
    chunks = deflated |> Base.url_encode64(padding: false) |> chunk(1_100)
    total = length(chunks)
    for {data, i} <- Enum.with_index(chunks, 1), do: %{id: id, index: i, total: total, data: data}
  end

  defp chunk(s, n) when byte_size(s) <= n, do: [s]
  defp chunk(s, n), do: [binary_part(s, 0, n) | chunk(binary_part(s, n, byte_size(s) - n), n)]

  defp start_inbox(dir, clock, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, make_ref())
    opts = [name: nil, dir: dir, clock: fn -> Agent.get(clock, & &1) end] ++ opts
    start_supervised!({Inbox, opts}, id: id)
  end

  defp at(clock, ms), do: Agent.update(clock, fn _ -> ms end)

  defp put(inbox, part), do: Inbox.put(part, server: inbox)

  defp put_all(inbox, parts), do: parts |> Enum.map(&put(inbox, &1)) |> List.last()

  defp file(dir), do: Path.join(dir, "handoff_inbox.json")

  test "a 20 kB summary: every link fits a 1200-character QR; parts arrive in any order, duplicates ignored",
       %{tmp_dir: dir, clock: clock} do
    summary = summary(20_000)
    links = Handoff.encode(Map.put(@handoff, :summary, summary))
    total = length(links)

    assert total > 2
    assert Enum.all?(links, &(byte_size(&1) <= 1200))
    assert Enum.all?(links, &String.starts_with?(&1, "operator://handoff?"))

    inbox = start_inbox(dir, clock)
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
       %{tmp_dir: dir, clock: clock} do
    summary = summary(3_000)
    a = Handoff.encode(Map.put(@handoff, :summary, summary))
    assert Handoff.encode(Map.put(@handoff, :summary, summary)) == a

    b = encode(3_000)
    inbox = start_inbox(dir, clock)
    [a1, a2 | a_rest] = parts(a)
    [b1 | _] = parts(b)

    assert put(inbox, a1) == {:partial, 1, length(a)}
    assert put(inbox, b1) == {:partial, 1, length(b)}
    assert put(inbox, a2) == {:partial, 2, length(a)}
    assert {:complete, %{summary: ^summary}} = put_all(inbox, a_rest)
  end

  test "a damaged chunk fails the whole set, which is dropped", %{tmp_dir: dir, clock: clock} do
    [p1, p2 | rest] = encode(3_000) |> parts()
    <<head::binary-size(100), c, tail::binary>> = p2.data
    damaged = %{p2 | data: head <> if(c == ?A, do: "B", else: "A") <> tail}

    inbox = start_inbox(dir, clock)
    put_all(inbox, [p1 | rest])

    assert put(inbox, damaged) == {:error, :corrupt}
    assert put(inbox, p1) == {:partial, 1, length(rest) + 2}
  end

  test "a code giving its set another part count starts the set over, so the real codes still complete it",
       %{tmp_dir: dir, clock: clock} do
    summary = summary(3_000)
    [first | _] = genuine = Handoff.encode(Map.put(@handoff, :summary, summary)) |> parts()
    total = length(genuine)
    inbox = start_inbox(dir, clock)

    assert put(inbox, %{first | total: 99}) == {:partial, 1, 99}
    assert put(inbox, first) == {:partial, 1, total}
    assert {:complete, %{summary: ^summary}} = put_all(inbox, genuine)
  end

  describe "size limits, the same for encode/1 and the phone" do
    test "a few hundred bytes of QR inflating to 100,000 lines are refused, not opened",
         %{tmp_dir: dir, clock: clock} do
      [part] = crafted(Jason.encode!(%{"v" => 1, "summary" => String.duplicate("\n", 100_000)}))
      assert byte_size(part.data) < 1_000

      assert put(start_inbox(dir, clock), part) == {:error, :too_large}
      assert Handoff.message(:too_large) =~ "too long for the phone"
    end

    test "inflating stops at the payload limit", %{tmp_dir: dir, clock: clock} do
      parts = crafted(Jason.encode!(%{"v" => 1, "summary" => String.duplicate("\n", 1_000_000)}))
      assert put_all(start_inbox(dir, clock), parts) == {:error, :too_large}
    end

    test "2,000 lines and 64,000 bytes go through; one more line or byte doesn't, on either side",
         %{tmp_dir: dir, clock: clock} do
      inbox = start_inbox(dir, clock)
      lines = String.duplicate("x\n", 1_999) <> "x"
      bytes = String.duplicate("y", 64_000)

      for summary <- [lines, bytes] do
        handoff = Map.put(@handoff, :summary, summary)
        assert {:complete, ^handoff} = put_all(inbox, handoff |> Handoff.encode() |> parts())
      end

      for summary <- [lines <> "\n", bytes <> "y"] do
        assert_raise ArgumentError, ~r/too long for the phone/, fn ->
          Handoff.encode(Map.put(@handoff, :summary, summary))
        end

        json = Jason.encode!(%{"v" => 1, "summary" => summary})
        assert put_all(inbox, crafted(json)) == {:error, :too_large}
      end
    end

    test "encode/1 refuses what the phone can't open, before any code; at the limits, the " <>
           "costliest JSON still opens",
         %{tmp_dir: dir, clock: clock} do
      assert_raise ArgumentError, fn ->
        Handoff.encode(Map.put(@handoff, :summary, String.duplicate("a", 2_000_000)))
      end

      # Control characters, which JSON escapes in up to 6 bytes each (no newlines).
      worst =
        for _ <- 1..64_000,
            into: "",
            do: <<Enum.random(Enum.to_list(1..9) ++ Enum.to_list(11..31))>>

      handoff = %{@handoff | title: String.duplicate("t", 500), cwd: "/a\n/b"}
      links = Handoff.encode(Map.put(handoff, :summary, worst))

      assert {:complete, %{summary: ^worst, title: title, cwd: "/a"}} =
               put_all(start_inbox(dir, clock), parts(links))

      assert byte_size(title) == 200
    end
  end

  describe "the inbox stays bounded" do
    # Three-part sets, one part in: every set stays open.
    defp opener(n), do: %{id: "0000000#{n}", index: 1, total: 3, data: "AAAA"}

    test "past 8 sets, the one least recently joined goes; the file holds 8",
         %{tmp_dir: dir, clock: clock} do
      inbox = start_inbox(dir, clock)

      for n <- 1..9 do
        at(clock, @t0 + n)
        assert put(inbox, opener(n)) == {:partial, 1, 3}
      end

      assert put(inbox, %{opener(1) | index: 2}) == {:partial, 1, 3}
      assert put(inbox, %{opener(9) | index: 2}) == {:partial, 2, 3}
      assert dir |> file() |> File.read!() |> Jason.decode!() |> map_size() == 8
    end

    test "past the byte limit, older sets go, never the one being joined",
         %{tmp_dir: dir, clock: clock} do
      inbox = start_inbox(dir, clock, max_bytes: 10_000)
      data = String.duplicate("A", 1_100)
      a = for i <- 1..5, do: %{id: "aaaaaaaa", index: i, total: 9, data: data}
      b = for i <- 1..5, do: %{id: "bbbbbbbb", index: i, total: 9, data: data}

      assert put_all(inbox, a) == {:partial, 5, 9}
      at(clock, @t0 + 1)
      assert put_all(inbox, b) == {:partial, 5, 9}
      assert put(inbox, %{hd(a) | index: 6}) == {:partial, 1, 9}
    end

    test "a set no part joined for 30 minutes is dropped", %{tmp_dir: dir, clock: clock} do
      [p1, p2, p3 | _] = parts = encode(3_000) |> parts()
      total = length(parts)
      inbox = start_inbox(dir, clock)

      assert put(inbox, p1) == {:partial, 1, total}
      at(clock, @t0 + 30 * @minute)
      assert put(inbox, p2) == {:partial, 2, total}
      # 30 minutes after the last part joined, not the first.
      at(clock, @t0 + 60 * @minute + 1)
      assert put(inbox, p3) == {:partial, 1, total}
    end

    test "expired sets are dropped at start and while nothing is scanned",
         %{tmp_dir: dir, clock: clock} do
      inbox = start_inbox(dir, clock, id: :first)
      assert {:partial, 1, 3} = put(inbox, opener(1))
      :ok = stop_supervised!(:first)

      at(clock, @t0 + 31 * @minute)
      start_inbox(dir, clock, id: :second)
      refute File.exists?(file(dir))
      :ok = stop_supervised!(:second)

      inbox = start_inbox(dir, clock, prune_ms: 10)
      assert {:partial, 1, 3} = put(inbox, opener(2))
      at(clock, @t0 + 62 * @minute)

      assert Enum.any?(1..100, fn _ ->
               Process.sleep(10)
               not File.exists?(file(dir))
             end)
    end
  end

  test "parts survive a restart", %{tmp_dir: dir, clock: clock} do
    [first | rest] = encode(3_000) |> parts()
    inbox = start_inbox(dir, clock, id: :before)
    assert {:partial, 1, _} = put(inbox, first)
    :ok = stop_supervised!(:before)

    inbox = start_inbox(dir, clock)
    assert {:complete, %{title: "Ship the QR handoff"}} = put_all(inbox, rest)
  end

  test "a handoff from a newer format is refused as such", %{tmp_dir: dir, clock: clock} do
    [part] = crafted(Jason.encode!(%{"v" => 2, "summary" => "later"}))
    assert put(start_inbox(dir, clock), part) == {:error, :unsupported_version}
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
