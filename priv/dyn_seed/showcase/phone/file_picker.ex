defmodule Operator.Dyn.Showcase.Phone.FilePicker do
  @moduledoc """
  Phone widget: the system document picker (`Mob.Files.pick/2`: Files on
  iOS, the storage picker on Android, so Downloads, Drive, iCloud, ...). It
  shows what came back (name, size, type) and, for text, the first lines.

  The picker hands back its own copy in the app's temporary files, where a
  screen can't read; `Operator.Core.Files.keep/2` copies it into the
  workspace's `inbox/`, and `Operator.Core.Files.read/1` reads it there.
  No permission is needed: the user chooses the file.
  """
  use Mob.Screen

  alias Operator.Core.Files
  alias Operator.Dyn.Showcase.Phone

  @preview_lines 12
  # Bigger files aren't read for the preview.
  @preview_max 1_000_000

  def entry do
    %{
      slug: :file_picker,
      name: "File picker",
      category: "Phone",
      order: 3,
      description: "Pick a document; see its name, size, type and first lines.",
      api: "Mob.Files, Operator.Core.Files"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: "Pick a file from the phone or a cloud drive.",
       files: [],
       kept: nil,
       preview: nil
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Row fill_width={true}>
          <Button
            text="Any file"
            background={:primary}
            text_color={:on_primary}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), {:pick, :any}}}
          />
          <Spacer size={12} />
          <Button
            text="A text file"
            background={:surface_raised}
            text_color={:on_surface}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), {:pick, :text}}}
          />
        </Row>
        {Enum.map(@files, &file_card/1)}
        {kept_line(@kept)}
        {preview(@preview)}
      </Column>
      """
    ])
  end

  defp file_card(file) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={12} />
      <Box
        fill_width={true}
        background={:surface}
        padding={:space_md}
        corner_radius={:radius_md}
        border_color={:border}
        border_width={1}
      >
        <Column fill_width={true}>
          <Text text={file[:name] || "(no name)"} text_size={:lg} text_color={:on_surface} />
          <Spacer size={4} />
          <Text
            text={"#{size(file[:size])} · #{file[:mime] || "unknown type"}"}
            text_size={:sm}
            text_color={:muted}
          />
        </Column>
      </Box>
    </Column>
    """
  end

  defp kept_line(nil), do: nil

  defp kept_line(path) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={8} />
      <Text text={"Kept in the workspace: #{path}"} text_size={:sm} text_color={:muted} />
    </Column>
    """
  end

  defp preview(nil), do: nil

  defp preview(text) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={12} />
      <Text text="First lines" text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <Box
        fill_width={true}
        background={:surface_raised}
        padding={:space_sm}
        corner_radius={:radius_sm}
        border_color={:border}
        border_width={1}
      >
        <Text text={text} text_size={:sm} text_color={:on_surface} />
      </Box>
    </Column>
    """
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:tap, {:pick, types}}, socket) do
    socket
    |> Mob.Socket.assign(status: "Choose a file…", files: [], kept: nil, preview: nil)
    |> Mob.Files.pick(types: [types])
  rescue
    _ in [ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket, :status, "There's no file picker on this device.")
  end

  # The picker can return several; the first one is previewed.
  defp widget({:files, :picked, [first | _] = files}, socket) do
    socket = Mob.Socket.assign(socket, status: picked_status(files), files: files)

    case Files.keep(first.path, first[:name]) do
      {:ok, kept} ->
        Mob.Socket.assign(socket, kept: kept, preview: first_lines(kept, first))

      {:error, why} ->
        Mob.Socket.assign(socket, :status, "Picked, but couldn't keep it: #{why}")
    end
  end

  defp widget({:files, :picked, []}, socket),
    do: Mob.Socket.assign(socket, :status, "Nothing was picked.")

  defp widget({:files, :cancelled}, socket),
    do: Mob.Socket.assign(socket, :status, "Cancelled: no file picked.")

  defp widget(_message, socket), do: socket

  defp picked_status([_]), do: "Picked one file."
  defp picked_status(files), do: "Picked #{length(files)} files; the first is previewed."

  # Text (by its type or because it decodes as UTF-8) shows its first lines.
  defp first_lines(path, file) do
    with true <- (file[:size] || 0) <= @preview_max,
         {:ok, data} <- Files.read(path),
         true <- text?(file[:mime], data) do
      data
      |> String.split("\n")
      |> Enum.take(@preview_lines)
      |> Enum.map_join("\n", &String.slice(&1, 0, 120))
    else
      false -> nil
      {:error, why} -> "(couldn't read it: #{inspect(why)})"
    end
  end

  defp text?("text/" <> _, data), do: String.valid?(data)
  defp text?(_mime, data), do: String.valid?(data) and not String.contains?(data, <<0>>)

  defp size(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)} MB"
  defp size(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)} KB"
  defp size(n) when is_integer(n), do: "#{n} bytes"
  defp size(_), do: "size unknown"
end
