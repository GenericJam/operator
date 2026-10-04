# mob_nfc

NFC for [Mob](https://github.com/GenericJam/mob) apps — read and write NDEF
tags, read raw tag UIDs, and emulate a tag (Android HCE). iOS `CoreNFC`
(iPhone 7+) / Android `NfcAdapter` + `HostApduService`.

| Capability | API | iOS | Android |
|---|---|---|---|
| Read NDEF | `start_reading/2` | ✅ | ✅ |
| Read raw tag (UID/type) | `start_reading(mode: :tag)` | ✅ | ✅ |
| Write NDEF | `write_ndef/3` | ✅ | ✅ |
| Emulate a tag (HCE) | `emulate_ndef/3` | — (unsupported) | ✅ read + writable |

All paths are device-verified (iPhone SE 3rd gen ↔ Moto G power 5G 2024).

## Install

```elixir
# mix.exs
{:mob_nfc, github: "GenericJam/mob_nfc"}
```

```elixir
# mob.exs — plugins are opt-in (a bare deps.get does nothing)
config :mob, :plugins, [:mob_nfc]
```

## Use

Calls return the `socket` unchanged; results arrive in `handle_info/2` as
`{:nfc, ...}` messages to the process that started the session.

```elixir
# Read
def handle_event("scan", _p, socket), do: {:noreply, MobNfc.start_reading(socket)}

def handle_info({:nfc, :ndef, %{ndef: bytes}}, socket) do
  records = MobNfc.Ndef.parse(bytes)   # one tested parser, shared across platforms
  uris = for r <- records, {:ok, u} <- [MobNfc.Ndef.decode_uri(r)], do: u
  {:noreply, assign(socket, :uris, uris)}
end

# Write
MobNfc.write_ndef(socket, MobNfc.Ndef.uri_record("https://mob.dev"))
MobNfc.write_ndef(socket, [MobNfc.Ndef.text_record("hi"), uri_rec])

# Emulate a tag (Android)
MobNfc.emulate_ndef(socket, MobNfc.Ndef.uri_record("https://mob.dev"))
MobNfc.emulate_ndef(socket, rec, writable: true)   # a reader can write into it
```

### Events (tagged `:nfc`)

```elixir
{:nfc, :session_started}
{:nfc, :ndef, %{tag_id: binary, ndef: binary, writable: boolean, max_size: integer}}
{:nfc, :tag, %{tag_id: binary, tech: binary}}      # a tag with no NDEF data
{:nfc, :written, %{bytes: integer}}                # write_ndef/3 succeeded
{:nfc, :emulation_started | :emulation_stopped}    # HCE lifecycle
{:nfc, :hce_read}                                  # a reader read the emulated tag
{:nfc, :hce_written, %{ndef: binary}}              # a reader wrote to it (writable HCE)
{:nfc, :session_ended, reason}                     # :done | :user_cancel | :timeout | ...
{:nfc, :error, reason}                             # :unavailable | :read_only | :too_small | ...
```

`ndef` is the **raw NDEF message bytes** — turn it into records with
`MobNfc.Ndef.parse/1` and decode Text/URI with `decode_text/1` / `decode_uri/1`.
`MobNfc.available?/0` reports whether the radio is present and enabled; reading
is a no-op on the simulator/emulator.

## Host setup

The plugin adds what it can automatically (Android `NFC` permission, iOS
`NFCReaderUsageDescription`). A few things mob_dev can't contribute yet must be
added by hand — the native build prints them as `host_requirements`:

- **iOS NFC entitlement** in `ios/<app>.entitlements` (+ `mix mob.provision`):
  ```xml
  <key>com.apple.developer.nfc.readersession.formats</key>
  <array><string>NDEF</string><string>TAG</string></array>
  ```
- **iOS raw-tag mode** (`mode: :tag`) needs an ISO7816 `select-identifiers` AID
  list in `ios/<app>.plist` (an array plist key mob_dev can't merge yet). iOS
  blocks EMV **payment** cards regardless (Secure Element).
- **Android HCE** (`emulate_ndef/3`) — nothing to add: the `<service>` and
  `res/xml/mob_nfc_hce_apduservice.xml` are contributed by mob_dev (≥ 0.6.19).
  While emulating in the foreground the app is the preferred HCE service, so
  other installed apps registering the NDEF AID don't intercept the reader.
- **Android** — add `<uses-feature android:name="android.hardware.nfc"
  android:required="false"/>` so NFC-less devices still install.

See the plugin manifest `host_requirements` for the exact XML snippets.

## Design notes

- **One NDEF parser/encoder** (`MobNfc.Ndef`), in Elixir, shared by both
  platforms — the native layer only ships raw bytes.
- **`MobNfc.Hce`** is a pure, tested reference implementation of the Type-4 Tag
  APDU state machine; the Android `HostApduService` mirrors it (an HCE service
  must answer readers even when the BEAM is down, so it can't delegate at
  runtime).
- 53 host tests cover the wire format, the API transport, and the HCE protocol;
  the native CoreNFC / `HostApduService` glue is verified on-device.
