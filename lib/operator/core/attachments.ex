defmodule Operator.Core.Attachments do
  @moduledoc """
  Files for the model from the phone: photos from the library, the
  camera, any app's documents. One implementation behind both the chat's
  `[attach]` (the files go with the user's next message, `Session.user/2`)
  and the agent's tools (`pick_photos`, `photos_recent`, `camera_photo`,
  `camera_snap`, `file_pick`; the files come back in the tool result,
  `tool_result/2`).

  The pickers and the camera go through the chat screen
  (`Operator.Core.Phone`, so the caller must not be the chat screen
  itself: it starts a task), then each file is kept in the workspace
  (`inbox/`; the agent's own snaps in `photos/`) so the agent can open it
  again, and becomes a `t:Operator.Core.Session.attachment/0`:

    * a picture: scaled down for the model (`Operator.Core.Images`), with
      its size, when and where it was taken (EXIF GPS when the file has it)
    * a text file: its text, up to the output budget
      (`Operator.Core.Artifacts.budget/0`); the rest is read with file_read
    * a PDF: sent as a document to models that take PDFs
    * anything else: its path, size and type

  `ctx` is a tool's context (`:data_dir`, `:phone_host`, `:thumbnail`, …).
  """

  alias Operator.Core.Artifacts
  alias Operator.Core.Files
  alias Operator.Core.Images
  alias Operator.Core.Session
  alias Operator.Core.Tools.FileTool
  alias Operator.Core.Tools.PhoneTool

  @type t :: Session.attachment()
  @type picked :: {:ok, [t()]} | {:ok, :cancelled} | {:error, String.t()}

  # A tool result carries at most this many pictures.
  @max_tool_pictures 5

  # ── from the phone ──

  @doc "The user picks up to `max` photos or videos from the library."
  @spec pick_photos(pos_integer(), map()) :: picked()
  def pick_photos(max, ctx) do
    with {:ok, items} when is_list(items) <-
           PhoneTool.call(:pick_photos, %{max: max}, ctx, 175_000) do
      {:ok, Enum.map(items, &library_item(&1, ctx))}
    end
  end

  @doc "The user takes a photo with the camera app."
  @spec take_photo(map()) :: picked()
  def take_photo(ctx) do
    with {:ok, %{path: path}} <- PhoneTool.call(:camera_photo, %{}, ctx, 175_000) do
      {:ok, [kept(path, ctx, "inbox", nil)]}
    end
  end

  @doc """
  A photo taken with no one at the shutter (`facing` `:back` / `:front`,
  `flash` `:off` / `:on` / `:auto`), kept as `photos/snap-<time>-<facing>.jpg`.
  The camera already scaled it for the model, so it goes as it is.
  """
  @spec snap(:back | :front, :off | :on | :auto, map()) :: picked()
  def snap(facing, flash, ctx) do
    with {:ok, %{path: path} = shot} <-
           PhoneTool.call(:camera_snap, %{facing: facing, flash: flash}, ctx, 115_000),
         stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S"),
         {:ok, kept} <- keep(path, ctx, "photos", "snap-#{stamp}-#{facing}.jpg"),
         {:ok, bytes} <- File.read(kept) do
      {:ok,
       [
         %{
           kind: :image,
           name: Path.basename(kept),
           path: kept,
           mime: "image/jpeg",
           about: "#{FileTool.size(byte_size(bytes))} · #{shot[:width]}×#{shot[:height]}",
           image: {"image/jpeg", bytes}
         }
       ]}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "The photo was taken but couldn't be read: #{reason}"}

      other ->
        other
    end
  end

  @doc """
  The user picks files with the system document picker (several at once;
  `types` as `Mob.Files.pick/2` takes them).
  """
  @spec pick_files([atom() | String.t()], map()) :: picked()
  def pick_files(types, ctx) do
    with {:ok, items} when is_list(items) <-
           PhoneTool.call(:pick_file, %{types: types}, ctx, 295_000) do
      {:ok, Enum.map(items, &picked_file(&1, ctx))}
    end
  end

  defp picked_file(%{path: src} = item, ctx), do: kept(src, ctx, "inbox", item[:name])

  @doc """
  A photo library item (`MobPhotos`: `%{path | uri, display_name, type,
  size}`): the picker's copy (a path) is kept in the inbox; one that is
  only a URI (`content://`, `ph://`, from `MobPhotos.list_media/2`) is
  shown from where it is.
  """
  @spec library_item(map(), map()) :: t()
  def library_item(item, ctx) do
    source = item[:path] || item[:uri]
    name = item[:display_name] || item[:name] || Path.basename(source || "?")

    cond do
      is_binary(item[:path]) and File.regular?(item.path) ->
        kept(item.path, ctx, "inbox", name)

      to_string(item[:type]) == "video" ->
        %{kind: :file, name: name, path: source, mime: "video/*", about: "a video (not shown)"}

      true ->
        picture(source, name, item[:size], ctx)
    end
  end

  # `src` kept in the workspace, as an attachment (one saying why, if it couldn't be).
  defp kept(src, ctx, dir, name) do
    case keep(src, ctx, dir, name) do
      {:ok, path} ->
        from_file(path, ctx)

      {:error, why} ->
        name = name || Path.basename(src)
        %{kind: :file, name: name, path: src, mime: "application/octet-stream", about: why}
    end
  end

  @doc """
  Keeps `src` in the workspace's `dir` as `name` (default its own name;
  `name-2`, `name-3`, … if taken) and returns the kept path. The picker's
  and the camera's temporary copies are moved; anything else is copied.
  """
  @spec keep(Path.t(), map(), String.t(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, String.t()}
  def keep(src, ctx, dir \\ "inbox", name \\ nil) do
    dir = Path.join(Files.workspace(ctx), dir)
    File.mkdir_p!(dir)

    if Path.dirname(Path.expand(src)) == Path.expand(dir),
      do: {:ok, src},
      else: copy(src, unique(dir, named(name, src)), ctx)
  end

  # The given name keeps the source's extension when it has none (iOS's
  # photo picker names a pick `IMG_0042`), so the copy is still a picture.
  defp named(nil, src), do: Path.basename(src)

  defp named(name, src) do
    if Path.extname(name) == "", do: name <> Path.extname(src), else: name
  end

  defp copy(src, dest, ctx) do
    case File.cp(src, dest) do
      :ok ->
        if temporary?(src, ctx), do: File.rm(src)
        {:ok, dest}

      {:error, reason} ->
        {:error, "couldn't keep it: " <> FileTool.posix(reason, src)}
    end
  end

  # Outside the workspace and shared storage: the picker's or camera's own copy.
  defp temporary?(src, ctx) do
    not Enum.any?(Files.roots(ctx), &String.starts_with?(Path.expand(src), &1.path <> "/"))
  end

  defp unique(dir, name) do
    name = name |> Path.basename() |> String.replace(~r/[\/\x00]/, "_")
    base = Path.rootname(name)
    ext = Path.extname(name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> Path.join(dir, name)
      n -> Path.join(dir, "#{base}-#{n}#{ext}")
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end

  # ── from a file ──

  @doc "An attachment for the file at `path` (a picture, text, a PDF or anything else)."
  @spec from_file(Path.t(), map()) :: t()
  def from_file(path, ctx \\ %{}) do
    size = File.stat!(path).size
    name = Path.basename(path)

    cond do
      Images.picture?(path) ->
        picture(path, name, size, ctx)

      String.downcase(Path.extname(path)) == ".pdf" ->
        pdf(path, name, size)

      FileTool.text?(path) ->
        text(path, name, size)

      true ->
        other(path, name, size)
    end
  end

  defp picture(source, name, size, ctx) do
    case Images.for_model(source, ctx) do
      {:ok, %{mime: mime, bytes: bytes, info: info}} ->
        about = Enum.reject([size && FileTool.size(size), Images.describe(info)], &is_nil/1)

        %{
          kind: :image,
          name: name,
          path: source,
          mime: Images.mime(name) || mime,
          about: Enum.join(about, " · "),
          image: {mime, bytes}
        }

      {:error, why} ->
        %{kind: :file, name: name, path: source, mime: "image/*", about: why}
    end
  end

  # What a provider takes as one document (Anthropic: 100 pages, 32 MB a
  # request); a longer or bigger PDF goes by its path. So does one whose
  # pages can't be counted or that is encrypted: a document the provider
  # rejects would be resent, and rejected, with every later request.
  @pdf_pages 100
  @pdf_bytes 20_000_000

  defp pdf(path, name, size) do
    pages = if size <= @pdf_bytes, do: pdf_pages(path)

    cond do
      size > @pdf_bytes ->
        other(path, name, size, "a PDF too big to send as a document", "application/pdf")

      pages == :not_pdf ->
        other(path, name, size, "named .pdf but not a PDF")

      pages == :encrypted ->
        other(path, name, size, "an encrypted PDF, not sent as a document", "application/pdf")

      pages == nil ->
        what = "a PDF whose pages couldn't be counted, not sent as a document"
        other(path, name, size, what, "application/pdf")

      pages > @pdf_pages ->
        what = "a #{pages}-page PDF, too long to send as a document"
        other(path, name, size, what, "application/pdf")

      true ->
        about = "#{FileTool.size(size)} · #{pages} page#{if pages == 1, do: "", else: "s"}"
        %{kind: :pdf, name: name, path: path, mime: "application/pdf", about: about, pages: pages}
    end
  end

  # The page count from the page objects or the page tree's /Count, also
  # inside compressed object streams (/ObjStm, Docusign, pdfTeX); nil if
  # neither shows; `:encrypted` with an /Encrypt dictionary; `:not_pdf`
  # without the header.
  defp pdf_pages(path) do
    case File.read!(path) do
      "%PDF-" <> _ = pdf ->
        if Regex.match?(~r{/Encrypt\b}, pdf), do: :encrypted, else: counted_pages(pdf)

      _ ->
        :not_pdf
    end
  end

  defp counted_pages(pdf) do
    pages =
      with 0 <- count_pages(pdf),
           do: pdf |> object_streams() |> Enum.join("\n") |> count_pages()

    if pages == 0, do: nil, else: pages
  end

  defp count_pages(pdf) do
    objects = length(Regex.scan(~r{/Type\s*/Page(?![a-zA-Z])}, pdf))

    counts =
      for [_, n] <- Regex.scan(~r{/Type\s*/Pages\b[^>]*?/Count\s+(\d+)}, pdf),
          do: String.to_integer(n)

    Enum.max([objects | counts])
  end

  defp object_streams(pdf) do
    for [data] <-
          Regex.scan(~r{/Type\s*/ObjStm[^>]*>>\s*stream\r?\n(.*?)endstream}s, pdf,
            capture: :all_but_first
          ),
        inflated <- inflate(data),
        do: inflated
  end

  defp inflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      [z |> :zlib.inflate(data) |> IO.iodata_to_binary()]
    rescue
      ErlangError -> []
    after
      :zlib.close(z)
    end
  end

  defp text(path, name, size) do
    budget = Artifacts.budget()
    {:ok, head} = File.open(path, [:read, :binary], &IO.binread(&1, budget))
    head = if is_binary(head), do: head, else: ""

    # Whole lines (the last may be cut mid-character), then where to read on;
    # bytes that aren't UTF-8 (a CP1252 export past the first 8 KB) become �.
    text =
      if size <= budget do
        String.replace_invalid(head)
      else
        lines = head |> String.split("\n") |> Enum.drop(-1)
        shown = Enum.join(lines, "\n")

        String.replace_invalid(shown) <>
          "\n[… #{FileTool.size(size - byte_size(shown))} more: " <>
          "read on with file_read, offset #{length(lines) + 1}]"
      end

    %{
      kind: :text,
      name: name,
      path: path,
      mime: text_mime(path),
      about: FileTool.size(size),
      text: text
    }
  end

  defp text_mime(path) do
    case String.downcase(Path.extname(path)) do
      ".md" -> "text/markdown"
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".html" -> "text/html"
      _ -> "text/plain"
    end
  end

  defp other(
         path,
         name,
         size,
         what \\ "not text or a picture",
         mime \\ "application/octet-stream"
       ) do
    %{
      kind: :file,
      name: name,
      path: path,
      mime: mime,
      about: "#{FileTool.size(size)}, #{what}: work with it through its path"
    }
  end

  # ── for a tool ──

  @doc """
  A tool's result for `picked`: `heading`, a line per file (its path and
  about line; a text file's text under it), and the pictures (at most
  #{@max_tool_pictures}).
  """
  @spec tool_result(picked(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def tool_result({:ok, :cancelled}, _heading), do: {:ok, "The user cancelled."}
  def tool_result({:ok, []}, _heading), do: {:ok, "Nothing was picked."}
  def tool_result({:error, _} = error, _heading), do: error

  def tool_result({:ok, attachments}, heading) do
    {lines, pictures} =
      attachments
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {a, n}, pictures ->
        named = if Path.basename(a.path) == a.name, do: "", else: "#{a.name} · "
        base = "#{n}. #{named}#{a.path} · #{a.about}"

        case a do
          %{image: picture} when length(pictures) < @max_tool_pictures ->
            {base <> " (shown)", [picture | pictures]}

          %{image: _} ->
            {base <> " (not shown: #{@max_tool_pictures} pictures per call)", pictures}

          %{kind: :text, text: text} ->
            {base <> "\n" <> text, pictures}

          _ ->
            {base, pictures}
        end
      end)

    text = Enum.join([heading | lines], "\n")

    case Enum.reverse(pictures) do
      [] -> {:ok, text}
      pictures -> {:ok, {:images, pictures, text}}
    end
  end

  @doc "One line for a chip: the name, its size, and whether the model will see a picture."
  @spec label(t(), boolean()) :: String.t()
  def label(a, images?) do
    size = a.about |> String.split(" · ", parts: 2) |> hd()
    note = if a.kind == :image and not images?, do: " (this model sees the path only)", else: ""
    "#{a.name} #{size}#{note}"
  end
end
