# mob_sms

SMS composer for [Mob](https://github.com/GenericJam/mob) apps. Opens the user's default messaging app pre-filled with recipient + body; the user taps Send to actually send. No dangerous permissions on either platform. Cross-platform surface (`MobSms.compose/2`), per-platform delivery asymmetry documented honestly.

## Install

Requires mob 0.9.1 or newer (the OTP flow's iOS half needs the
`text_content_type` prop on `<TextField>`, added in that release).

```elixir
def deps do
  [
    {:mob,     "~> 0.9.1"},
    {:mob_sms, "~> 0.2"}
  ]
end
```

In `mob.exs`, activate the plugin:

```elixir
config :mob, :plugins, [:mob_sms]
```

## Usage

```elixir
MobSms.compose(socket,
  to: "+15551234567",
  body: "Join me on Sample App: https://example.com/i/ABC123"
)
```

Both `:to` and `:body` are optional. Omit `:to` to let the user pick a recipient from Contacts inside the composer.

Result arrives as a message to the calling process:

```elixir
def handle_info({:sms, :sent},            socket), do: ...  # iOS
def handle_info({:sms, :cancelled},       socket), do: ...  # iOS
def handle_info({:sms, :composer_opened}, socket), do: ...  # Android
def handle_info({:sms, :not_available},   socket), do: ...  # both
```

## Per-platform delivery — the asymmetry to know

* **iOS** — `MFMessageComposeViewController` is presented as a sheet inside your app. The system delegate reports `:sent`, `:cancelled`, or `:failed` reliably. `:not_available` means the device cannot send SMS (simulator, no cellular / iMessage capability, no SIM).

* **Android** — `Intent.ACTION_SENDTO` with `smsto:` opens the user's default SMS app externally. Android does not reliably tell the host app whether the user tapped Send or cancelled — most SMS apps do not set an activity result. The plugin delivers `:composer_opened` once the composer is showing (or `:not_available` if no SMS-capable app is installed) and stops there. If knowing what the user did afterwards matters to your flow, plan around this asymmetry rather than assuming a `:sent`.

This asymmetry is by design at the platform layer, not something the plugin can paper over. Android intentionally hands the user off to a separate app rather than embedding a sheet; iOS presents inline and can observe the outcome.

## Common use cases

- **Invite codes** — "Join me on X, here's the link" — the canonical fit
- **Share a link / share a file** — user picks a friend inside the composer
- **Tell a friend** — referral flows without your app needing to know the friend's number
- **Verification workaround** — send a code to a manually-provided number without SMS gateway costs

## One-time code (OTP) autofill

The 0.2.0 addition. Verification codes delivered by SMS flow into the app
without the user typing them — iOS via QuickType autofill above the keyboard,
Android via Google Play Services' SMS Retriever (no `READ_SMS` permission,
no Play Store review gate).

```elixir
# On the screen owning the OTP field. Pass the SAME atom to `on_receive`
# that the text field uses for `on_change` — both platforms deliver the
# code as {:change, tag, value}, matching the field's normal keystroke
# shape.
def mount(_params, _session, socket) do
  {:ok, MobSms.OneTimeCode.arm(socket, on_receive: :code)}
end

def render(assigns) do
  ~MOB"""
  <TextField
    value={@code}
    on_change={{self(), :code}}
    keyboard={:number}
    text_content_type={:one_time_code}
  />
  """
end

def handle_info({:change, :code, value}, socket) do
  # Fires on BOTH platforms — iOS QuickType tap OR Android SMS Retriever.
  # The plugin translates Android's raw delivery into the on_change shape.
  {:noreply, Mob.Socket.assign(socket, code: value)}
end

def handle_info({:sms_otp, :timeout}, socket) do
  # Optional. Android-only sad path: 5-min retriever timeout, GMS
  # failure, or evicted by a subsequent arm/2. iOS never fires this.
  {:noreply, socket}
end
```

The `text_content_type: :one_time_code` prop tells iOS Messages to
surface the code in QuickType. `arm/2` starts the Android SMS Retriever
and spawns a tiny proxy that translates the delivery into the same
`{:change, tag, code}` shape iOS uses — one handler per screen.

Server-side SMS format for Android:

```
Your Sample App code is: 123456
<blank line>
FA+9qCX9VSu
```

The 11-char suffix is `base64(sha256("<package_name> <signing_cert_sha256_hex>"))[:11]`
— it's what Google Play Services uses to route the SMS to your specific
app. See `MobSms.OneTimeCode`'s docs for the debug-vs-release cert
distinction and Google's `AppSignatureHelper` snippet for computing the
hash during development. iOS doesn't need the hash — its SMS format is
any natural-language "your code is 123456" pattern.

See the full contract, per-platform behaviour, and edge cases in
`MobSms.OneTimeCode`'s module documentation.

## What this plugin is NOT

Not silent-send. iOS has no public API for sending SMS without the user tapping Send; Apple treats that as a bright-line spam surface. Android *can* silent-send via `SmsManager.sendTextMessage` under the `SEND_SMS` runtime permission, but Google Play rejects that permission request for most non-SMS-centric apps (the "Permissions Declaration" gate).

If you have a real reason to bypass the sheet on Android — and can accept iOS being permanently in composer mode — a separate `send/2` on this module can land in a later release. Talk to us before designing around it.

## Related

- [MOB epic MOB-257](https://linear.app/mobframework/issue/MOB-257) — the mob_wake plugin arc, which covers the *receive* side of push notifications for apps that want the "wake me when something happens" flow that people often reach for background tasks to build.

## License

MIT.
