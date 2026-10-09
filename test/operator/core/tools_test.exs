defmodule Operator.Core.ToolsTest do
  use ExUnit.Case, async: false

  alias Operator.Core.Phone
  alias Operator.Core.ToolRegistry
  alias Operator.Core.Tools.Clipboard
  alias Operator.Core.Tools.Friction
  alias Operator.Core.Tools.HttpGet
  alias Operator.Core.Tools.Notes
  alias Operator.Core.Tools.PickPhotos

  @moduletag :tmp_dir

  test "notes: append and read back, and its selftest passes", %{tmp_dir: dir} do
    ctx = %{data_dir: dir}
    assert {:ok, "(no notes yet)"} = Notes.run(%{"action" => "read"}, ctx)

    assert {:ok, "Appended. Notes now have 1 lines."} =
             Notes.run(%{"action" => "append", "text" => "milk"}, ctx)

    assert {:ok, "milk\n"} = Notes.run(%{"action" => "read"}, ctx)
    assert {:error, _} = Notes.run(%{"action" => "append"}, ctx)
    assert {:error, _} = Notes.run(%{"action" => "delete"}, ctx)
    assert Notes.selftest() == :ok
  end

  test "friction: entries survive across sessions; open first, resolved on request", %{
    tmp_dir: dir
  } do
    a = %{data_dir: dir, session_id: "s1"}
    b = %{data_dir: dir, session_id: "s2"}
    log = &Friction.run(Map.put(&1, "action", "log"), &2)

    assert {:ok, "Logged as #1. 1 open."} =
             log.(%{"what" => "guide swaps args", "would_help" => "fix it"}, a)

    assert {:ok, "Logged as #2. 2 open."} = log.(%{"what" => "no cube mesh"}, b)

    assert {:ok, "#1 resolved."} =
             Friction.run(%{"action" => "resolve", "id" => 1, "how" => "helper"}, b)

    assert {:ok, open} = Friction.run(%{"action" => "list"}, a)
    assert open =~ "#2" and open =~ "no cube mesh"
    refute open =~ "#1"
    assert {:ok, all} = Friction.run(%{"action" => "list", "all" => true}, a)
    assert all =~ "#1" and all =~ "[resolved: helper]" and all =~ "(would help: fix it)"

    assert [%{"session" => "s1", "resolved" => "helper"}, %{"session" => "s2"} = second] =
             Friction.entries(dir)

    refute Map.has_key?(second, "resolved")

    assert {:error, "no entry #9"} =
             Friction.run(%{"action" => "resolve", "id" => 9, "how" => "x"}, a)

    assert {:error, _} = log.(%{"what" => ""}, a)
  end

  test "looks up core tools and takes new ones at runtime" do
    start_supervised!(ToolRegistry)

    assert {:ok, Notes} = ToolRegistry.lookup("notes")

    assert :ok = ToolRegistry.register(Operator.Test.Tools.Echo)
    assert {:ok, Operator.Test.Tools.Echo} = ToolRegistry.lookup("echo")
    assert {:error, :not_a_tool} = ToolRegistry.register(String)

    :ok = ToolRegistry.unregister("echo")
    assert ToolRegistry.lookup("echo") == :error
  end

  defp responding(status, type, body) do
    me = self()

    respond = fn req ->
      send(me, {:requested, req.url, req.headers})
      headers = if type, do: %{"content-type" => [type]}, else: %{}
      Req.Response.new(status: status, headers: headers, body: body)
    end

    %{respond: respond}
  end

  describe "http_get" do
    test "returns status, type and text; error statuses are errors" do
      ctx = responding(200, "text/html; charset=utf-8", "<p>hi</p>")

      assert {:ok, "HTTP 200 text/html; charset=utf-8\n\n<p>hi</p>"} =
               HttpGet.run(
                 %{"url" => "https://x.dev/a", "headers" => %{"accept" => "text/html"}},
                 ctx
               )

      assert_received {:requested, %URI{host: "x.dev", path: "/a"}, headers}
      assert headers["accept"] == ["text/html"]

      assert {:error, "HTTP 404 application/json\n\n{}"} =
               HttpGet.run(%{"url" => "http://x.dev"}, responding(404, "application/json", "{}"))
    end

    test "refuses non-http URLs, bad headers, binary and oversized bodies" do
      ctx = responding(200, "text/plain", "ok")

      for url <- ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.dev", "https://", "x.dev"] do
        assert {:error, "not an http(s) URL" <> _} = HttpGet.run(%{"url" => url}, ctx)
      end

      refute_received {:requested, _, _}
      assert {:error, _} = HttpGet.run(%{"url" => "https://x.dev", "headers" => %{"a" => 1}}, ctx)

      assert {:error, msg} =
               HttpGet.run(%{"url" => "https://x.dev"}, responding(200, "image/png", <<137, 80>>))

      assert msg =~ "image/png (2 bytes) is not text"

      big = String.duplicate("a", 2_000_001)

      assert {:error, msg} =
               HttpGet.run(%{"url" => "https://x.dev"}, responding(200, "text/plain", big))

      assert msg =~ "over 2 MB"

      # no content type: text if it's UTF-8
      assert {:ok, _} = HttpGet.run(%{"url" => "https://x.dev"}, responding(200, nil, "plain"))

      assert {:error, _} =
               HttpGet.run(%{"url" => "https://x.dev"}, responding(200, nil, <<255, 0>>))

      assert HttpGet.selftest() == :ok
    end
  end

  test "clipboard: write then read; empty and background reads say why" do
    {:ok, store} = Agent.start_link(fn -> :empty end)

    fake =
      {fn -> Agent.get(store, & &1) end, fn t -> Agent.update(store, fn _ -> {:ok, t} end) end}

    ctx = %{clipboard: fake}

    assert {:ok, "(the clipboard is empty" <> _} = Clipboard.run(%{"action" => "read"}, ctx)

    assert {:ok, "Copied 5 characters" <> _} =
             Clipboard.run(%{"action" => "write", "text" => "héllo"}, ctx)

    assert {:ok, "héllo"} = Clipboard.run(%{"action" => "read"}, ctx)
    assert {:error, _} = Clipboard.run(%{"action" => "write", "text" => ""}, ctx)
    assert {:error, _} = Clipboard.run(%{"action" => "paste"}, ctx)
    assert Clipboard.selftest() == :ok
  end

  test "pick_photos: the model sees each picked photo with its metadata; videos are listed",
       %{tmp_dir: dir} do
    path = Path.join(dir, "mob_pick_1.jpg")
    File.write!(path, "12345")
    thumb = Path.join(dir, "thumb.jpg")

    host =
      spawn(fn ->
        receive do
          {:phone_request, ref, from, :pick_photos, _args} ->
            Phone.reply(
              from,
              ref,
              {:ok,
               [%{path: path, type: :image}, %{path: Path.join(dir, "gone.mov"), type: "video"}]}
            )
        end
      end)

    kept = Path.join(dir, "data/workspace/inbox/mob_pick_1.jpg")

    thumbnail = fn ^kept, opts ->
      assert opts[:max_size] <= 1568
      File.write!(thumb, "small")

      {:ok,
       %{
         path: thumb,
         width: 1568,
         height: 1176,
         orig_width: 4000,
         orig_height: 3000,
         taken_at: "2026-10-03T14:02:11-06:00",
         latitude: 51.0447,
         longitude: -114.0719,
         make: "motorola",
         model: "moto g"
       }}
    end

    ctx = %{phone_host: host, thumbnail: thumbnail, data_dir: Path.join(dir, "data")}
    assert {:ok, {:images, [{"image/jpeg", "small"}], text}} = PickPhotos.run(%{"max" => 2}, ctx)

    assert text ==
             "Picked:\n" <>
               "1. #{kept} · 5 B · 4000×3000 · taken 2026-10-03T14:02:11-06:00 · " <>
               "GPS 51.0447, -114.0719 · motorola moto g (shown)\n" <>
               "2. #{Path.join(dir, "gone.mov")} · a video (not shown)"

    # the picker's copy is moved into the inbox; the scaled copy is read and removed
    refute File.exists?(path)
    refute File.exists?(thumb)
  end
end
