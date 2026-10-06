defmodule Operator.Core.FileToolsTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Files
  alias Operator.Core.Phone
  alias Operator.Core.Tools.FileCopy
  alias Operator.Core.Tools.FileDelete
  alias Operator.Core.Tools.FileList
  alias Operator.Core.Tools.FilePick
  alias Operator.Core.Tools.FileRead
  alias Operator.Core.Tools.FileWrite

  @moduletag :tmp_dir

  # A workspace, a "shared" root (Android's shared storage, behind All files
  # access) and the rest of the data dir, which no root covers.
  setup %{tmp_dir: dir} do
    workspace = Path.join(dir, "data/workspace")
    shared = Path.join(dir, "shared")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(shared, "Download"))
    File.write!(Path.join(dir, "data/settings.json"), "secret")

    roots = [
      %{name: "workspace", path: workspace, access: :read_write, about: "own"},
      %{name: "shared", path: shared, access: :read_write, about: "shared storage"}
    ]

    %{
      ctx: %{file_roots: roots, shared_access: :granted},
      workspace: workspace,
      shared: shared,
      dir: dir
    }
  end

  test "paths outside the roots are refused, also through .. and symlinks", %{
    ctx: ctx,
    dir: dir,
    workspace: ws
  } do
    secret = Path.join(dir, "data/settings.json")
    assert {:error, msg} = FileRead.run(%{"path" => secret}, ctx)
    assert msg =~ "#{secret} is outside the places files may be used"

    assert {:error, "../settings.json is outside" <> _} =
             FileRead.run(%{"path" => "../settings.json"}, ctx)

    File.ln_s!(Path.join(dir, "data"), Path.join(ws, "escape"))

    assert {:error, "escape/settings.json is outside" <> _} =
             FileRead.run(%{"path" => "escape/settings.json"}, ctx)

    assert {:error, _} = FileWrite.run(%{"path" => "/etc/x", "content" => "no"}, ctx)
    assert File.read!(secret) == "secret"
  end

  test "write, append, read lines with offset and limit; relative paths are in the workspace",
       %{ctx: ctx, workspace: ws} do
    body = Enum.map_join(1..5, "", &"line #{&1}\n")

    assert {:ok, "Wrote " <> _} =
             FileWrite.run(%{"path" => "notes/a.txt", "content" => body}, ctx)

    assert {:ok, "Appended 7 bytes to " <> _} =
             FileWrite.run(
               %{"path" => "notes/a.txt", "content" => "line 6\n", "append" => true},
               ctx
             )

    file = Path.join(ws, "notes/a.txt")
    assert {:ok, text} = FileRead.run(%{"path" => file, "offset" => 2, "limit" => 2}, ctx)
    assert text =~ "2\tline 2\n3\tline 3\n"
    assert text =~ "read on with offset 4"
    refute text =~ "line 4"

    assert {:ok, all} = FileRead.run(%{"path" => "notes/a.txt"}, ctx)
    assert all =~ "6\tline 6\n"
    refute all =~ "read on"
  end

  test "base64 writes bytes; a binary file is described, a picture is shown", %{ctx: ctx} do
    bytes = <<0, 1, 2, 255>>

    assert {:ok, _} =
             FileWrite.run(
               %{"path" => "b.bin", "content" => Base.encode64(bytes), "encoding" => "base64"},
               ctx
             )

    assert {:ok, text} = FileRead.run(%{"path" => "b.bin"}, ctx)
    assert text =~ "binary, 4 B. First bytes (hex): 000102ff"

    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0xFF, 0xD9>>

    {:ok, _} =
      FileWrite.run(
        %{"path" => "p.JPG", "content" => Base.encode64(jpeg), "encoding" => "base64"},
        ctx
      )

    # without the photo plugin (the host) a small JPEG goes as it is
    no_plugin = Map.put(ctx, :thumbnail, fn _, _ -> {:error, :unavailable} end)

    assert {:ok, {:images, [{"image/jpeg", ^jpeg}], text}} =
             FileRead.run(%{"path" => "p.JPG"}, no_plugin)

    assert text =~ "p.JPG (8 B)"
  end

  test "list: the roots without a path, a directory's entries with one", %{
    ctx: ctx,
    shared: shared
  } do
    assert {:ok, roots} = FileList.run(%{}, ctx)
    assert roots =~ "workspace: "
    assert roots =~ "shared: #{shared}"

    File.write!(Path.join(shared, "Download/report.pdf"), "pdf")
    File.mkdir_p!(Path.join(shared, "Download/old"))
    assert {:ok, listing} = FileList.run(%{"path" => Path.join(shared, "Download")}, ctx)
    assert [_header, "old/  " <> _, "report.pdf  3 B  " <> _] = String.split(listing, "\n")
  end

  test "shared storage needs All files access: a refusal is the tool's answer", %{
    ctx: ctx,
    shared: shared
  } do
    denied = %{ctx | shared_access: "All files access is off for Operator."}

    assert {:error, "All files access is off" <> _} =
             FileList.run(%{"path" => Path.join(shared, "Download")}, denied)

    # the workspace needs no permission
    assert {:ok, _} = FileList.run(%{"path" => "."}, denied)
  end

  test "copy out to shared storage, move, and no silent overwrite", %{
    ctx: ctx,
    shared: shared,
    workspace: ws
  } do
    File.write!(Path.join(ws, "out.csv"), "a,b\n")
    download = Path.join(shared, "Download")

    assert {:ok, "Copied " <> _} = FileCopy.run(%{"from" => "out.csv", "to" => download}, ctx)
    assert File.read!(Path.join(download, "out.csv")) == "a,b\n"

    assert {:error, msg} = FileCopy.run(%{"from" => "out.csv", "to" => download}, ctx)
    assert msg =~ "#{Path.join(download, "out.csv")} already exists"

    assert {:ok, "Moved " <> _} =
             FileCopy.run(%{"from" => "out.csv", "to" => "kept.csv", "move" => true}, ctx)

    refute File.exists?(Path.join(ws, "out.csv"))
    assert File.read!(Path.join(ws, "kept.csv")) == "a,b\n"

    assert {:error, "Can't put " <> _} =
             FileCopy.run(%{"from" => download, "to" => Path.join(download, "inner")}, ctx)
  end

  test "delete: files, empty directories, whole trees only in the workspace, never a root", %{
    ctx: ctx,
    workspace: ws,
    shared: shared
  } do
    File.mkdir_p!(Path.join(ws, "d/e"))
    File.write!(Path.join(ws, "d/e/f.txt"), "x")

    assert {:error, msg} = FileDelete.run(%{"path" => "d"}, ctx)
    assert msg =~ "#{Path.join(ws, "d")} is a directory"

    assert {:ok, "Deleted " <> _} = FileDelete.run(%{"path" => "d", "recursive" => true}, ctx)
    refute File.exists?(Path.join(ws, "d"))

    assert {:error, msg} = FileDelete.run(%{"path" => ws, "recursive" => true}, ctx)
    assert msg =~ "#{ws} is the workspace root itself"
    assert File.dir?(ws)

    # shared storage (the user's photos): no tree at once, a file at a time
    camera = Path.join(shared, "DCIM/Camera")
    File.mkdir_p!(camera)
    File.write!(Path.join(camera, "a.jpg"), "jpg")
    dcim = Path.join(shared, "DCIM")

    for path <- [dcim, camera] do
      assert {:error, msg} = FileDelete.run(%{"path" => path, "recursive" => true}, ctx)
      assert msg =~ "deleted only inside the workspace"
    end

    assert File.read!(Path.join(camera, "a.jpg")) == "jpg"
    assert {:ok, _} = FileDelete.run(%{"path" => Path.join(camera, "a.jpg")}, ctx)
    assert {:ok, _} = FileDelete.run(%{"path" => camera}, ctx)
    refute File.exists?(camera)
    assert File.dir?(dcim)
  end

  test "a move across file systems that can't remove the whole source says what's left", %{
    workspace: ws
  } do
    [src, dest] = [Path.join(ws, "src"), Path.join(ws, "dest")]
    File.mkdir_p!(Path.join(src, "locked"))
    File.write!(Path.join(src, "locked/a.txt"), "a")
    File.chmod!(Path.join(src, "locked"), 0o500)

    on_exit(fn ->
      for d <- [src, dest], do: File.chmod(Path.join(d, "locked"), 0o700)
    end)

    assert {:error, msg} = FileCopy.move_across(src, dest)
    assert msg =~ "Copied #{src} to #{dest}"
    assert msg =~ "only partly removed"
    assert File.read!(Path.join(dest, "locked/a.txt")) == "a"
  end

  test "file_pick copies picked files into the inbox without clobbering", %{
    ctx: ctx,
    dir: dir,
    workspace: ws
  } do
    File.mkdir_p!(Path.join(ws, "inbox"))
    File.write!(Path.join(ws, "inbox/a.pdf"), "old")
    picked = Path.join(dir, "mob_file_a.pdf")
    File.write!(picked, "new")

    host =
      spawn(fn ->
        receive do
          {:phone_request, ref, from, :pick_file, %{types: [:pdf, "csv"]}} ->
            Phone.reply(
              from,
              ref,
              {:ok, [%{path: picked, name: "a.pdf", mime: "application/pdf", size: 3}]}
            )
        end
      end)

    assert {:ok, text} =
             FilePick.run(%{"types" => ["pdf", "csv"]}, Map.put(ctx, :phone_host, host))

    assert text == "Picked:\n#{Path.join(ws, "inbox/a-2.pdf")} · application/pdf · 3 B"
    assert File.read!(Path.join(ws, "inbox/a.pdf")) == "old"
    assert File.read!(Path.join(ws, "inbox/a-2.pdf")) == "new"
  end

  test "Dyn code's file calls stay inside the roots", %{dir: dir} do
    data = Path.join(dir, "dyn_data")
    ctx = %{data_dir: data}
    # Files' Dyn-facing calls take the default roots: the workspace under the data dir
    assert {:ok, _abs, %{name: "workspace"}} = Files.resolve("x.txt", :write, ctx)
    assert {:error, _} = Files.resolve(Path.join(data, "sessions/s.jsonl"), :read, ctx)
  end
end
