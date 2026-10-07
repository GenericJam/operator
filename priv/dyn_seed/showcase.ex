defmodule Operator.Dyn.Showcase do
  @moduledoc """
  The catalog of the component library, opened from the welcome screen or
  the terminal's `[menu]` › components: every Mishka Chelekom widget
  `mix mob.new` showcases (mob_new 0.6.5), and conventional widgets for the
  phone's capabilities (`Operator.Dyn.Showcase.Phone.*`, the category
  "Phone"), one front screen each. Adding one is one screen module plus one
  line here.

  Each screen has `entry/0` (its slug, name, category, order and
  description; a phone widget also `api`, the APIs it shows). A component
  has `examples/0` (`Operator.Dyn.Showcase.Example`s) and draws itself
  through `Operator.Dyn.Showcase.Page`; a phone widget is a working screen
  drawn through `Operator.Dyn.Showcase.Phone`. Every page has "use this"
  (`use_this/1`), which hands the entry to the agent.
  """

  alias Operator.Dyn.Showcase.Components, as: C
  alias Operator.Dyn.Showcase.Phone, as: P

  @doc "All entries (each with the screen `:module` and its source `:path`), sorted by category, order, name."
  def all do
    (components() ++ media() ++ system() ++ radios())
    |> Enum.sort_by(&{&1.category, Map.get(&1, :order, 0), &1.name})
  end

  defp components do
    [
      component(C.Drawer.entry(), C.Drawer),
      component(C.Accordion.entry(), C.Accordion),
      component(C.Separator.entry(), C.Separator),
      component(C.Switch.entry(), C.Switch),
      component(C.Progress.entry(), C.Progress),
      component(C.Meter.entry(), C.Meter),
      component(C.Collapsible.entry(), C.Collapsible),
      component(C.Avatar.entry(), C.Avatar),
      component(C.Slider.entry(), C.Slider),
      component(C.Dialog.entry(), C.Dialog),
      component(C.AlertDialog.entry(), C.AlertDialog),
      component(C.Tabs.entry(), C.Tabs),
      component(C.Chip.entry(), C.Chip),
      component(C.Pill.entry(), C.Pill),
      component(C.Mark.entry(), C.Mark),
      component(C.Highlight.entry(), C.Highlight),
      component(C.Checkbox.entry(), C.Checkbox),
      component(C.Radio.entry(), C.Radio),
      component(C.RadioGroup.entry(), C.RadioGroup),
      component(C.CheckboxGroup.entry(), C.CheckboxGroup),
      component(C.Toggle.entry(), C.Toggle),
      component(C.ToggleGroup.entry(), C.ToggleGroup),
      component(C.SegmentedControl.entry(), C.SegmentedControl),
      component(C.EmptyState.entry(), C.EmptyState),
      component(C.Spoiler.entry(), C.Spoiler),
      component(C.ActionIcon.entry(), C.ActionIcon),
      component(C.ScrollArea.entry(), C.ScrollArea),
      component(C.Code.entry(), C.Code),
      component(C.Toast.entry(), C.Toast),
      component(C.Popover.entry(), C.Popover),
      component(C.Menu.entry(), C.Menu),
      component(C.Tooltip.entry(), C.Tooltip),
      component(C.ContextMenu.entry(), C.ContextMenu),
      component(C.Toolbar.entry(), C.Toolbar),
      component(C.ColorSwatch.entry(), C.ColorSwatch),
      component(C.LoadingOverlay.entry(), C.LoadingOverlay),
      component(C.Skeleton.entry(), C.Skeleton),
      component(C.SemiCircleProgress.entry(), C.SemiCircleProgress),
      component(C.RollingNumber.entry(), C.RollingNumber),
      component(C.PreviewCard.entry(), C.PreviewCard),
      component(C.ThemeIcon.entry(), C.ThemeIcon),
      component(C.Field.entry(), C.Field),
      component(C.NumberField.entry(), C.NumberField),
      component(C.OtpField.entry(), C.OtpField),
      component(C.TagsInput.entry(), C.TagsInput),
      component(C.Select.entry(), C.Select),
      component(C.Combobox.entry(), C.Combobox),
      component(C.Autocomplete.entry(), C.Autocomplete),
      component(C.HueSlider.entry(), C.HueSlider),
      component(C.AlphaSlider.entry(), C.AlphaSlider),
      component(C.AngleSlider.entry(), C.AngleSlider),
      component(C.ColorPicker.entry(), C.ColorPicker),
      component(C.ColorInput.entry(), C.ColorInput),
      component(C.Tree.entry(), C.Tree),
      component(C.TreeSelect.entry(), C.TreeSelect),
      component(C.Splitter.entry(), C.Splitter),
      component(C.OverflowList.entry(), C.OverflowList),
      component(C.JsonInput.entry(), C.JsonInput),
      component(C.NavLink.entry(), C.NavLink),
      component(C.FloatingWindow.entry(), C.FloatingWindow),
      component(C.DatePicker.entry(), C.DatePicker)
    ]
  end

  # Phone widgets: camera, microphone, scanner, 3D, models.
  defp media do
    [
      widget(P.AudioRecorder.entry(), P.AudioRecorder),
      widget(P.Camera.entry(), P.Camera),
      widget(P.QrScanner.entry(), P.QrScanner),
      widget(P.TfliteClassify.entry(), P.TfliteClassify)
    ]
  end

  # Phone widgets: location, sensors, files, notifications, feedback, sharing.
  defp system do
    []
  end

  # Phone widgets: Bluetooth, NFC, MIDI.
  defp radios do
    [
      widget(P.Bluetooth.entry(), P.Bluetooth),
      widget(P.Nfc.entry(), P.Nfc),
      widget(P.Midi.entry(), P.Midi)
    ]
  end

  defp component(entry, module),
    do: Map.merge(entry, %{module: module, path: "showcase/components/#{entry.slug}.ex"})

  # A phone widget, `Operator.Dyn.Showcase.Phone.<Name>` in `showcase/phone/<slug>.ex`.
  defp widget(entry, module),
    do: Map.merge(entry, %{module: module, path: "showcase/phone/#{entry.slug}.ex"})

  @doc "Entries grouped `[{category, [entry, ...]}, ...]`, categories alphabetical."
  def by_category do
    all()
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  @doc "The entry for a slug, or nil."
  def get(slug), do: Enum.find(all(), &(&1.slug == slug))

  @doc """
  "Use this": the terminal opens with a draft asking the agent to use the
  entry `slug` (its name and library path), unsent, for the user to finish
  ("... in my notes screen") and send.
  """
  def use_this(slug) do
    case get(slug) do
      nil -> {:error, :unknown}
      entry -> Operator.Core.Terminal.draft(draft(entry))
    end
  end

  @doc "The draft `use_this/1` hands the agent."
  def draft(entry),
    do: "Use the #{entry.name} #{kind(entry)} (library path #{entry.path}) in "

  defp kind(%{category: "Phone"}), do: "widget"
  defp kind(_entry), do: "component"
end
