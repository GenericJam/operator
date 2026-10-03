defmodule Operator.Core.ToolsTest do
  use ExUnit.Case, async: false

  alias Operator.Core.ToolRegistry
  alias Operator.Core.Tools.Clipboard
  alias Operator.Core.Tools.HttpGet
  alias Operator.Core.Tools.Notes

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

  test "the registry offers core tools and takes new ones at runtime" do
    start_supervised!(ToolRegistry)

    # sorted by name
    assert Enum.map(ToolRegistry.list(), & &1.name()) == [
             "camera_photo",
             "clipboard",
             "dyn_delete",
             "dyn_edit",
             "dyn_files",
             "dyn_propose",
             "dyn_read",
             "dyn_reset",
             "dyn_status",
             "dyn_write",
             "http_get",
             "location",
             "notes",
             "notify",
             "pick_photos",
             "read_artifact"
           ]

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
end
