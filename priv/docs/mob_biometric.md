# mob_biometric

Biometric authentication (Face ID / Touch ID / fingerprint) for apps built
with [Mob](https://hexdocs.pm/mob) — `Mob.Biometric`, extracted from mob core
as a plugin.

No permission dialog: the OS biometric prompt *is* the auth flow, using the
device's existing enrollment.

## Installation

```elixir
# mix.exs
{:mob_biometric, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_biometric]
```

The plugin manifest merges `NSFaceIDUsageDescription` into the host
Info.plist at build time (Face ID requires it; Touch ID doesn't) and pulls in
`androidx.biometric:biometric:1.1.0` on Android. No manifest permission
needed from the host.

## Usage

```elixir
socket = MobBiometric.authenticate(socket, reason: "Confirm payment")

def handle_info({:biometric, :success}, socket), do: ...
def handle_info({:biometric, :failure}, socket), do: ...
def handle_info({:biometric, :not_available}, socket), do: ...
```

`:not_available` means the device has no biometric hardware or the user has
not enrolled any biometrics.

## Platforms

- **Android** works on mob's `ComponentActivity` host via the platform
  `android.hardware.biometrics.BiometricPrompt` (API 28+), which is built
  from a `Context` and does not require a `FragmentActivity`. Fixed in
  0.1.3; device-verified on Moto G power 5G (2024). Cancel / user-dismiss
  → `:failure`; no-hardware, none-enrolled, or lockout → `:not_available`.
- **iOS** uses `LAContext` with `deviceOwnerAuthenticationWithBiometrics`
  (Touch ID and Face ID). Explicit user/system/app cancellation → `:failure`;
  lockout, repeated mismatch, not-available, not-enrolled, and
  passcode-not-set → `:not_available` (aligned with Android in 0.1.4).

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
