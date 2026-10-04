# mob_notify

Local and push notifications for apps built with [Mob](https://hexdocs.pm/mob)
— the device half of `Mob.Notify`, extracted from mob core as a plugin. Owns
scheduling, cancellation, and push registration; pairs with the server-side
[mob_push](https://hex.pm/packages/mob_push) package for sending.

## Installation

```elixir
# mix.exs
{:mob_notify, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_notify]
```

Requires the `:notifications` permission
(`Mob.Permissions.request(socket, :notifications)`). Android 13+'s
`POST_NOTIFICATIONS` and the `firebase-messaging` gradle dep are merged from
this plugin's manifest; iOS needs no plist key.

## Usage

Local notifications:

```elixir
MobNotify.schedule(socket,
  id:    "reminder_1",
  title: "Time to check in",
  body:  "Open the app to see today's updates",
  at:    ~U[2026-04-16 09:00:00Z],   # or delay_seconds: 60
  data:  %{screen: "reminders"}
)

MobNotify.cancel(socket, "reminder_1")

def handle_info({:notification, %{presentation: :tap, id: id, data: data, source: :local}}, socket), do: ...
```

Push registration (call once after `:notifications` is granted):

```elixir
socket = MobNotify.register_push(socket)

def handle_info({:push_token, platform, token}, socket) do
  # platform is :ios | :android — store both, send with MobPush.send/3 server-side
end

def handle_info({:notification, %{presentation: :tap, title: t, body: b, data: d, source: :push}}, socket), do: ...
```

### What arrives

Delivery lives in mob core; this plugin is the API surface. Every
notification arrives as `{:notification, notif}` (mob > 0.9.7; see
[`Mob.Notification`](https://hexdocs.pm/mob/Mob.Notification.html)):

```elixir
%{
  presentation: :tap,          # :foreground = arrived while the app was open
  action: "default",           # nil for :foreground
  source: :local,              # or :push
  id: "reminder_1",
  title: "Time to check in",
  body: "Open the app to see today's updates",
  data: %{screen: "reminders"} # atom keys at the top level
}
```

A `:foreground` arrival still shows the system banner; tapping it then
delivers `:tap`. A tap that launched the app from a killed state arrives at
the root screen once it has mounted, exactly once.

It goes to the process that last called `register_push/1` (on iOS, also
`schedule/2`) while that process is alive, otherwise to the screen currently
showing.

On Android, this plugin ships the app's FCM receiver, `MobFirebaseService`,
and declares it (and the boot re-arm receiver) in the app's manifest at
native build time; the app needs no Kotlin of its own:

- **Tap on a push the system tray showed** (a message with a
  `notification` block, sent while the app was in the background or killed):
  one `:tap`, on cold launch, warm launch, or from the shade while the app is
  open again. `id` is the FCM message id and `data`
  the message's data keys (FCM's own `google.*`, `from` and `collapse_key`
  are dropped); `title` and `body` are `nil`, because Android doesn't pass
  the displayed text to the app. A push from mob_push carries
  `mob_notification_json`, which the generated `MainActivity` delivers
  instead, with the title and body. Each tap is delivered once, also when
  Android re-creates the activity or relaunches it from Recents.
- **Push arriving while the app is in the foreground**: one `:foreground`.
  For a message with a `notification` block mob_notify also shows the banner
  (Android shows none for a foreground app); tapping it delivers `:tap`.
- **Data-only push while the app is in the background**: not delivered
  (it's a silent push, not a notification). One with a `mob_wake_id` goes to
  mob_wake in any state, when the app has it.
- **Token refresh**: `{:push_token, :android, token}` to the process that
  called `register_push/1`, or on its next `register_push/1` if none has.
- `:foreground` arrivals of local notifications, and taps while nothing is
  registered, need the `NotificationReceiver` and `MainActivity` that mob_new
  0.6.3 generates. Apps generated earlier get no `:foreground` arrival for a
  local notification and lose a warm tap when nothing is registered.

Android hands FCM to one service. An app that declares its own
`FirebaseMessagingService` (the `MobFirebaseService` mob_new 0.1.45–0.4.10
generated, or mob_wake's `MobWakeFcmService`) keeps receiving FCM through it
and mob_notify's stands by. Delete the app's declaration and class to switch
to mob_notify's, which also forwards mob_wake's messages and tokens. Until
then the app's own service must add `"presentation": "foreground"` to the JSON
it passes to `MobBridge.nativeDeliverNotification` (both the
`mob_notification_json` string and the object it builds), or mob reads every
push that arrives while the app is open as a tap.

## Host app requirements

Manual steps the build can't automate (the FCM service and boot receiver
are declared by the native build, mob_dev >= 0.6.19):

1. **Android — Firebase wiring**: the host `build.gradle` needs the
   `com.google.gms.google-services` plugin + a `google-services.json` from
   the Firebase console (buildscript classpath entries are host-level).
   mob_new doesn't generate this, so add it by hand; Android push needs it.
2. **iOS — APNs token forwarding**: the host AppDelegate must call
   `mob_send_push_token(hex)` (exported by mob core) in
   `didRegisterForRemoteNotificationsWithDeviceToken` (the mob_new template
   does).
3. **Android — display receiver**: scheduled notifications display via a
   `<applicationId>.NotificationReceiver` BroadcastReceiver declared in
   `AndroidManifest.xml` (the mob_new template ships it) — this plugin only
   arms the alarm.
4. **iOS silent APNs**: see the manifest's `host_requirements` (Info.plist
   background mode, Apple Developer Portal push capability).

## Limits

- Local scheduling is device-verified on both platforms. Android FCM receipt
  (foreground arrival, banner tap, warm and cold tray taps, token on first
  launch) is verified on an API 35 emulator; iOS remote push needs real APNs
  credentials plus the mob_push server side.
- An **unauthorized iOS app drops scheduled notifications silently** —
  request `:notifications` before scheduling.
- The wire contract with mob_push is pinned by shared fixtures
  (`test/fixtures/push_contract.exs`, vendored identically in both repos).

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.

## License

MIT
