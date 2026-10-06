defmodule Operator.Core.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Artifacts
  alias Operator.Core.Attachments
  alias Operator.Core.Session

  @moduletag :tmp_dir

  test "a file becomes a picture, text, a PDF or a path by what it is", %{tmp_dir: dir} do
    write = fn name, body ->
      path = Path.join(dir, name)
      File.write!(path, body)
      path
    end

    assert %{kind: :image, image: {"image/png", <<137, 80, 78, 71>>}, about: "4 B" <> _} =
             Attachments.from_file(write.("shot.png", <<137, 80, 78, 71>>))

    assert %{kind: :text, mime: "text/csv", text: "a,b\n1,2\n", about: "8 B"} =
             Attachments.from_file(write.("t.csv", "a,b\n1,2\n"))

    pages =
      "%PDF-1.7\n1 0 obj << /Type /Pages /Kids [2 0 R 3 0 R] /Count 2 >>\n" <>
        "2 0 obj << /Type /Page >>\n3 0 obj << /Type /Page >>"

    assert %{kind: :pdf, mime: "application/pdf", pages: 2, about: about} =
             Attachments.from_file(write.("r.pdf", pages))

    assert about =~ ~r/^\d+ B · 2 pages$/

    long = "%PDF-1.7\n" <> String.duplicate("<< /Type /Page >>\n", 101)

    assert %{kind: :file, mime: "application/pdf", about: about} =
             Attachments.from_file(write.("long.pdf", long))

    assert about =~ "a 101-page PDF, too long to send as a document"
    assert %{kind: :file} = Attachments.from_file(write.("fake.pdf", "hello"))

    # sent as a document only when counted and readable: one the provider rejects
    # would be resent with every later request
    assert %{kind: :file, mime: "application/pdf", about: about} =
             Attachments.from_file(write.("odd.pdf", "%PDF-1.7\nno page tree here"))

    assert about =~ "pages couldn't be counted"

    locked = pages <> "\ntrailer << /Encrypt 9 0 R /Root 1 0 R >>"

    assert %{kind: :file, mime: "application/pdf", about: about} =
             Attachments.from_file(write.("locked.pdf", locked))

    assert about =~ "an encrypted PDF"

    # page objects in a compressed object stream (Docusign, pdfTeX) are counted too
    packed = :zlib.compress("1 0 2 30 << /Type /Pages /Kids [] /Count 120 >>")

    objstm =
      "%PDF-1.7\n5 0 obj << /Type /ObjStm /N 1 /First 8 /Filter /FlateDecode >>\nstream\n" <>
        packed <> "\nendstream\nendobj\n"

    assert %{kind: :file, about: about} = Attachments.from_file(write.("signed.pdf", objstm))
    assert about =~ "a 120-page PDF"

    assert %{kind: :file, about: "3 B, not text or a picture" <> _} =
             Attachments.from_file(write.("blob.bin", <<0, 1, 2>>))
  end

  test "text that stops being UTF-8 after the first 8 KB still makes a valid message",
       %{tmp_dir: dir} do
    path = Path.join(dir, "export.csv")
    File.write!(path, String.duplicate("a,b\n", 3_000) <> <<"caf", 0xE9, "\n">>)

    %{kind: :text, text: text} = attachment = Attachments.from_file(path)
    assert String.valid?(text)
    assert text =~ "caf\uFFFD"
    assert Jason.encode!(Session.user("", attachments: [attachment]))
  end

  test "a picked photo named without an extension (iOS) is still a picture", %{tmp_dir: dir} do
    src = Path.join(dir, "mob_pick_abc.png")
    File.write!(src, <<137, 80, 78, 71>>)
    ctx = %{data_dir: Path.join(dir, "data")}

    assert %{kind: :image, name: "IMG_0042.png", path: path} =
             Attachments.library_item(%{path: src, type: :image, name: "IMG_0042"}, ctx)

    assert path == Path.join(dir, "data/workspace/inbox/IMG_0042.png")
  end

  test "a long text file goes up to the output budget, in whole lines, then where to read on",
       %{tmp_dir: dir} do
    line = String.duplicate("x", 99) <> "\n"
    count = div(Artifacts.budget(), 100) + 50
    path = Path.join(dir, "log.txt")
    File.write!(path, String.duplicate(line, count))

    %{text: text} = Attachments.from_file(path)
    shown = div(Artifacts.budget(), 100)

    assert String.starts_with?(text, String.duplicate(line, shown - 1) <> String.trim(line))
    assert text =~ ~r/\[… [\d.]+ KB more: read on with file_read, offset #{shown + 1}\]$/
    assert byte_size(text) < Artifacts.budget() + 100
  end

  test "keep never overwrites and moves only temporary copies", %{tmp_dir: dir} do
    ctx = %{data_dir: Path.join(dir, "data")}
    tmp = Path.join(dir, "picker_copy.txt")
    File.write!(tmp, "one")

    assert {:ok, first} = Attachments.keep(tmp, ctx, "inbox", "n.txt")
    refute File.exists?(tmp)
    File.write!(tmp, "two")
    assert {:ok, second} = Attachments.keep(tmp, ctx, "inbox", "n.txt")
    assert Path.basename(second) == "n-2.txt"
    assert {File.read!(first), File.read!(second)} == {"one", "two"}

    # a workspace file is copied, not moved
    assert {:ok, copy} = Attachments.keep(first, ctx, "photos")
    assert File.exists?(first) and File.exists?(copy)

    assert {:error, "couldn't keep it: " <> _} =
             Attachments.keep(Path.join(dir, "gone.txt"), ctx)
  end

  test "a chip says when the model will only get a picture's path" do
    photo = %{kind: :image, name: "IMG_1.jpg", about: "1.2 MB · 4000×3000", path: "/p"}
    assert Attachments.label(photo, true) == "IMG_1.jpg 1.2 MB"
    assert Attachments.label(photo, false) == "IMG_1.jpg 1.2 MB (this model sees the path only)"
  end
end
