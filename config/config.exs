import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Operator.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :operator, ecto_repos: [Operator.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Operator.Repo

# The Mishka tags front screens write in `~MOB` (mob_mishka's composites and
# their slot tags, as `mix mob.new` lists them). Front screens compile on the
# phone (Operator.Core.Dyn), where the sigil can't read the plugin's manifest,
# and the manifest has no slot tags: without this list every one warns.
config :mob, :extra_tags, ~w(
  MishkaAccordion
  MishkaAccordionItem
  MishkaActionIcon
  MishkaAlertDialog
  MishkaAlertDialogAction
  MishkaAlphaSlider
  MishkaAnchor
  MishkaAngleSlider
  MishkaAutocomplete
  MishkaAvatar
  MishkaBurger
  MishkaCheckbox
  MishkaCheckboxGroup
  MishkaCheckboxGroupItem
  MishkaChip
  MishkaCloseButton
  MishkaCode
  MishkaCollapsible
  MishkaColorInput
  MishkaColorPicker
  MishkaColorSwatch
  MishkaCombobox
  MishkaContextMenu
  MishkaDialog
  MishkaDialogDescription
  MishkaDialogFooter
  MishkaDialogTitle
  MishkaDialogTrigger
  MishkaDrawer
  MishkaDrawerFooter
  MishkaDrawerTrigger
  MishkaEmptyState
  MishkaEmptyStateActions
  MishkaEmptyStateIndicator
  MishkaField
  MishkaFieldset
  MishkaFloatingIndicator
  MishkaFloatingWindow
  MishkaFloatingWindowHandle
  MishkaHighlight
  MishkaHueSlider
  MishkaJsonInput
  MishkaLoadingOverlay
  MishkaMark
  MishkaMarquee
  MishkaMaskInput
  MishkaMenu
  MishkaMenuCheckbox
  MishkaMenuItem
  MishkaMenuLabel
  MishkaMenuRadio
  MishkaMenuSeparator
  MishkaMenuSubmenu
  MishkaMenubar
  MishkaMeter
  MishkaNavLink
  MishkaNavigationMenu
  MishkaNumberField
  MishkaNumberFormatter
  MishkaOtpField
  MishkaOverflowList
  MishkaPill
  MishkaPillsInput
  MishkaPopover
  MishkaPopoverArrow
  MishkaPopoverClose
  MishkaPopoverDescription
  MishkaPopoverTitle
  MishkaPopoverTrigger
  MishkaPreviewCard
  MishkaPreviewCardTrigger
  MishkaProgress
  MishkaRadio
  MishkaRadioGroup
  MishkaRadioGroupOption
  MishkaRollingNumber
  MishkaScrollArea
  MishkaScroller
  MishkaSegmentedControl
  MishkaSegmentedControlOption
  MishkaSelect
  MishkaSelectOption
  MishkaSemiCircleProgress
  MishkaSeparator
  MishkaSkeleton
  MishkaSlider
  MishkaSplitter
  MishkaSpoiler
  MishkaSwitch
  MishkaTab
  MishkaTabs
  MishkaTagsInput
  MishkaThemeIcon
  MishkaToast
  MishkaToastClose
  MishkaToastItem
  MishkaToggle
  MishkaToggleGroup
  MishkaToggleGroupItem
  MishkaToolbar
  MishkaToolbarButton
  MishkaToolbarInput
  MishkaToolbarLink
  MishkaToolbarSeparator
  MishkaTooltip
  MishkaTree
  MishkaTreeNode
  MishkaTreeSelect
  MishkaVisuallyHidden
)

# llm_db reads priv/llm_db/snapshot.json at runtime by default, but mob_dev
# ships deps' ebins without their priv/, and Application.app_dir/2 does not
# resolve on device. Operator.LLMCatalog embeds an Anthropic + OpenAI trim of
# the snapshot and sets :snapshot_path at boot. (`compile_embed: true` also
# works but embeds all 230 providers: a 12.9 MB beam and a ~19 s first lookup
# on the emulator; it is compile_env, so switching needs
# `mix deps.compile llm_db --force`.)
config :llm_db, compile_embed: false

# req_llm loads a .env file from the CWD at boot by default; there is none
# on the phone, and the model tokens come from the sign-ins (Operator.Auth).
config :req_llm, load_dotenv: false

# The spike agent's model is the :operator alias, resolved when an agent
# starts (Operator.Diag.agent/0).
config :jido_ai,
  model_aliases: %{operator: "anthropic:claude-haiku-4-5"}

# time_zone_info (a jido dependency) reads its data from its priv/ dir by
# default, which isn't shipped to the device. Operator.TzData embeds the file
# and sets :file_system's path at boot.
config :time_zone_info, data_persistence: TimeZoneInfo.DataPersistence.FileSystem

# mob_deliver: over-the-air updates of Operator's own code, published from
# the Mac (Operator.Deliver, docs/DESIGN.md §1). mob_dev evaluates this file
# on the Mac when it builds the app and ships the result inside the build,
# where mob_deliver reads its trust settings (delivered code can't change
# them). The trust root is the public half of the signing key `mix
# operator.deliver.key` wrote; without that file it is nil and the phone
# never installs an update. The endpoint is deliberately not here: the
# phone learns it from the `mix operator.deliver.qr` code and keeps it in
# its settings (Operator.Deliver).
deliver_signing_key = Path.expand("~/.config/operator/deliver_signing.key")

trusted_publish_key =
  with {:ok, "ed25519-private:" <> encoded} <- File.read(deliver_signing_key),
       {:ok, <<seed::binary-size(32)>>} <- Base.decode64(String.trim(encoded)) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    "ed25519:" <> Base.encode64(public)
  else
    _ -> nil
  end

# mob_rapier's Rustler on_load looks its NIF up through this app's lib dir:
# the phone's flat OTP bundle has no per-dep lib dirs (MOB-254).
config :mob_rapier, :otp_app, :operator

# Ash (mob_ash): front screens declare their own resources, which Ash refuses
# to compile until it knows how to count string length.
config :ash, default_string_length_count: :codepoints

config :mob_deliver,
  trusted_publish_key: trusted_publish_key,
  app: "com.genericjam.operator",
  # The public channel: sideloaded release installs and `mix operator.publish`
  # both use it.
  channel: "stable",
  # While the app is in front; also at launch and from Diagnostics.
  poll_interval: :timer.minutes(5),
  # No mob_wake: no silent-push checks. No store listing: no update gate.
  on_push: false,
  store_url: nil

if config_env() == :test do
  # Host tests: no trust root (tests set their own), and mob_deliver's store
  # (its application runs in the test VM) away from the home directory.
  config :mob_deliver,
    trusted_publish_key: nil,
    root: Path.join(System.tmp_dir!(), "operator_test_mob_deliver")
else
  # One "stable launch" for both layers: the Dyn Keeper's (first frame,
  # then 10 s or the user leaving) also ends a delivered update's
  # probation (Operator.Deliver.launch_stable/0).
  config :operator, Operator.Core.Dyn, on_stable: {Operator.Deliver, :launch_stable, []}
end
