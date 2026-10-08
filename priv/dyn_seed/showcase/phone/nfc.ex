defmodule Operator.Dyn.Showcase.Phone.Nfc do
  @moduledoc """
  Read one NFC tag: its id, its technology and its NDEF records.

  NFC needs no runtime permission (Android declares it in the manifest;
  iOS shows its own reader sheet). The reader runs until the first tag, a
  30-second timeout or Stop, whichever comes first: Android's reader mode
  and iOS's session both keep reading until stopped.
  """
  use Mob.Screen

  alias MobNfc.Ndef
  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @read_ms 30_000

  def entry do
    %{
      slug: :nfc,
      name: "NFC",
      category: "Phone",
      order: 2,
      description: "Read an NFC tag: its id, technology and NDEF records.",
      api: "MobNfc, MobNfc.Ndef"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       # The running read's timeout ref; nil when idle.
       reading: nil,
       tag: nil,
       status: "Tap Read, then hold the back of the phone against a tag."
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
            text={if @reading, do: "Reading…", else: "Read a tag"}
            on_tap={{self(), :read}}
            disabled={@reading != nil}
            weight={1}
          />
          <Spacer size={12} />
          <Button
            text="Stop"
            on_tap={{self(), :stop}}
            disabled={@reading == nil}
            background={:surface_raised}
            text_color={:on_surface}
            weight={1}
          />
        </Row>
        <Spacer size={16} />
        <Column :if={@tag} fill_width={true}>
          {tag_card(@tag)}
        </Column>
      </Column>
      """,
      Kit.gap(8),
      Kit.muted("Android: NFC must be on (Settings → Connected devices). iPhone 7 or later.")
    ])
  end

  defp tag_card(tag) do
    ~MOB"""
    <Box background={:surface} padding={:space_md} corner_radius={:radius_md} fill_width={true}>
      <Column fill_width={true}>
        <Text text="Tag" text_size={:lg} text_color={:on_surface} />
        <Spacer size={8} />
        <Text :for={line <- tag.facts} text={line} text_size={:sm} text_color={:muted} />
        <Spacer size={12} />
        <Text text={records_title(tag.records)} text_size={:base} text_color={:on_surface} />
        <Spacer size={4} />
        <Text :for={record <- tag.records} text={record} text_size={:sm} text_color={:on_surface} />
      </Column>
    </Box>
    """
  end

  defp records_title([]), do: "No NDEF records"
  defp records_title([_]), do: "1 NDEF record"
  defp records_title(records), do: "#{length(records)} NDEF records"

  # ── events ──

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, nfc(message, socket)}
    end
  end

  def terminate(_reason, socket) do
    _ = stop(socket, "Stopped.")
    :ok
  end

  defp nfc({:tap, :read}, socket) do
    ref = make_ref()
    Process.send_after(self(), {:read_timeout, ref}, @read_ms)

    socket
    |> MobNfc.start_reading(alert: "Hold the top of your iPhone near a tag")
    |> Mob.Socket.assign(reading: ref, status: "Hold the phone against a tag…")
  end

  defp nfc({:tap, :stop}, socket), do: stop(socket, "Stopped.")

  defp nfc({:read_timeout, ref}, %{assigns: %{reading: ref}} = socket),
    do: stop(socket, "No tag within 30 seconds. Tap Read to try again.")

  defp nfc({:nfc, :session_started}, socket),
    do: Mob.Socket.assign(socket, :status, "Ready: hold the phone against a tag…")

  # A tag with NDEF data: the raw message is parsed here, the same on both platforms.
  defp nfc({:nfc, :ndef, info}, socket) do
    facts = [id_line(info.tag_id) | capacity(info)]

    records = info.ndef |> Ndef.parse() |> Enum.map(&describe/1)
    socket |> Mob.Socket.assign(:tag, %{facts: facts, records: records}) |> stop("Read a tag.")
  end

  # A tag without NDEF data (a transit or bank card): only its id and technology.
  defp nfc({:nfc, :tag, info}, socket) do
    facts = [id_line(info.tag_id), "Technology: #{tech(info.tech)}"]
    socket |> Mob.Socket.assign(:tag, %{facts: facts, records: []}) |> stop("Read a tag.")
  end

  # Stopping, the iOS sheet's Cancel or its own timeout ends the session.
  defp nfc({:nfc, :session_ended, :user_cancel}, socket),
    do: Mob.Socket.assign(socket, reading: nil, status: "Cancelled.")

  defp nfc({:nfc, :session_ended, :timeout}, socket),
    do: Mob.Socket.assign(socket, reading: nil, status: "No tag in time. Tap Read to try again.")

  defp nfc({:nfc, :session_ended, _reason}, socket), do: Mob.Socket.assign(socket, :reading, nil)

  defp nfc({:nfc, :error, reason}, socket),
    do: Mob.Socket.assign(socket, reading: nil, status: error_text(reason))

  defp nfc(_message, socket), do: socket

  defp stop(%{assigns: %{reading: nil}} = socket, status),
    do: Mob.Socket.assign(socket, :status, status)

  defp stop(socket, status) do
    socket
    |> MobNfc.stop_reading()
    |> Mob.Socket.assign(reading: nil, status: status)
  end

  defp describe(record) do
    with :error <- text_record(record), :error <- uri_record(record) do
      other_record(record)
    end
  end

  defp text_record(record) do
    case Ndef.decode_text(record) do
      {:ok, %{text: text, lang: lang}} -> "Text (#{lang}): #{text}"
      :error -> :error
    end
  end

  defp uri_record(record) do
    case Ndef.decode_uri(record) do
      {:ok, uri} -> "Link: #{uri}"
      :error -> :error
    end
  end

  defp other_record(%{tnf: 2, type: mime, payload: payload}),
    do: "#{mime}: #{byte_size(payload)} bytes"

  defp other_record(%{tnf: tnf, type: type, payload: payload}),
    do: "Type #{inspect(type)} (TNF #{tnf}): #{byte_size(payload)} bytes"

  # iOS's NDEF reader reports no capacity (writable false, max_size 0 as placeholders).
  defp capacity(%{max_size: 0}), do: []

  defp capacity(info),
    do: ["Writable: #{yes_no(info.writable)}", "Capacity: #{info.max_size} bytes"]

  # iOS's NDEF reader doesn't see the tag id either (an empty string).
  defp id_line(""), do: "Id: (not given on iOS)"

  # "04a2b3c4" → "04:A2:B3:C4", the way tag ids are usually printed.
  defp id_line(id) do
    pairs = id |> String.upcase() |> String.graphemes() |> Enum.chunk_every(2)
    "Id: " <> Enum.map_join(pairs, ":", &Enum.join/1)
  end

  # Android's tech list is class names: "android.nfc.tech.NfcA,..." → "NfcA, ...".
  defp tech(""), do: "(not given on iOS)"

  defp tech(list),
    do:
      list |> String.split(",") |> Enum.map_join(", ", &(&1 |> String.split(".") |> List.last()))

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"

  defp error_text(:disabled),
    do: "NFC is off. Turn it on in Settings → Connected devices, then tap Read."

  defp error_text(none) when none in [:unavailable, :unsupported],
    do: "This device has no NFC reader (an emulator has none)."

  defp error_text(:not_ndef), do: "That tag isn't NDEF-formatted."

  defp error_text(:read_failed),
    do: "The read failed: hold the tag still against the phone and try again."

  defp error_text(reason), do: "NFC error: #{inspect(reason)}"
end
