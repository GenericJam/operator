defmodule Operator.Dyn.Showcase do
  @moduledoc """
  The catalog of the component gallery: every Mishka Chelekom widget
  `mix mob.new` showcases (mob_new 0.6.5), one front screen each. Adding a
  component to the gallery is one screen module plus one line here.

  Each component screen has `entry/0` (its slug, name, category, order and
  description) and `examples/0` (`Operator.Dyn.Showcase.Example`s) and
  draws itself through `Operator.Dyn.Showcase.Page`.
  """

  alias Operator.Dyn.Showcase.Components, as: C

  @doc "All entries (each with the screen `:module`), sorted by category, order, name."
  def all do
    [
      Map.put(C.Drawer.entry(), :module, C.Drawer),
      Map.put(C.Accordion.entry(), :module, C.Accordion),
      Map.put(C.Separator.entry(), :module, C.Separator),
      Map.put(C.Switch.entry(), :module, C.Switch),
      Map.put(C.Progress.entry(), :module, C.Progress),
      Map.put(C.Meter.entry(), :module, C.Meter),
      Map.put(C.Collapsible.entry(), :module, C.Collapsible),
      Map.put(C.Avatar.entry(), :module, C.Avatar),
      Map.put(C.Slider.entry(), :module, C.Slider),
      Map.put(C.Dialog.entry(), :module, C.Dialog),
      Map.put(C.AlertDialog.entry(), :module, C.AlertDialog),
      Map.put(C.Tabs.entry(), :module, C.Tabs),
      Map.put(C.Chip.entry(), :module, C.Chip),
      Map.put(C.Pill.entry(), :module, C.Pill),
      Map.put(C.Mark.entry(), :module, C.Mark),
      Map.put(C.Highlight.entry(), :module, C.Highlight),
      Map.put(C.Checkbox.entry(), :module, C.Checkbox),
      Map.put(C.Radio.entry(), :module, C.Radio),
      Map.put(C.RadioGroup.entry(), :module, C.RadioGroup),
      Map.put(C.CheckboxGroup.entry(), :module, C.CheckboxGroup),
      Map.put(C.Toggle.entry(), :module, C.Toggle),
      Map.put(C.ToggleGroup.entry(), :module, C.ToggleGroup),
      Map.put(C.SegmentedControl.entry(), :module, C.SegmentedControl),
      Map.put(C.EmptyState.entry(), :module, C.EmptyState),
      Map.put(C.Spoiler.entry(), :module, C.Spoiler),
      Map.put(C.ActionIcon.entry(), :module, C.ActionIcon),
      Map.put(C.ScrollArea.entry(), :module, C.ScrollArea),
      Map.put(C.Code.entry(), :module, C.Code),
      Map.put(C.Toast.entry(), :module, C.Toast),
      Map.put(C.Popover.entry(), :module, C.Popover),
      Map.put(C.Menu.entry(), :module, C.Menu),
      Map.put(C.Tooltip.entry(), :module, C.Tooltip),
      Map.put(C.ContextMenu.entry(), :module, C.ContextMenu),
      Map.put(C.Toolbar.entry(), :module, C.Toolbar),
      Map.put(C.ColorSwatch.entry(), :module, C.ColorSwatch),
      Map.put(C.LoadingOverlay.entry(), :module, C.LoadingOverlay),
      Map.put(C.Skeleton.entry(), :module, C.Skeleton),
      Map.put(C.SemiCircleProgress.entry(), :module, C.SemiCircleProgress),
      Map.put(C.RollingNumber.entry(), :module, C.RollingNumber),
      Map.put(C.PreviewCard.entry(), :module, C.PreviewCard),
      Map.put(C.ThemeIcon.entry(), :module, C.ThemeIcon),
      Map.put(C.Field.entry(), :module, C.Field),
      Map.put(C.NumberField.entry(), :module, C.NumberField),
      Map.put(C.OtpField.entry(), :module, C.OtpField),
      Map.put(C.TagsInput.entry(), :module, C.TagsInput),
      Map.put(C.Select.entry(), :module, C.Select),
      Map.put(C.Combobox.entry(), :module, C.Combobox),
      Map.put(C.Autocomplete.entry(), :module, C.Autocomplete),
      Map.put(C.HueSlider.entry(), :module, C.HueSlider),
      Map.put(C.AlphaSlider.entry(), :module, C.AlphaSlider),
      Map.put(C.AngleSlider.entry(), :module, C.AngleSlider),
      Map.put(C.ColorPicker.entry(), :module, C.ColorPicker),
      Map.put(C.ColorInput.entry(), :module, C.ColorInput),
      Map.put(C.Tree.entry(), :module, C.Tree),
      Map.put(C.TreeSelect.entry(), :module, C.TreeSelect),
      Map.put(C.Splitter.entry(), :module, C.Splitter),
      Map.put(C.OverflowList.entry(), :module, C.OverflowList),
      Map.put(C.JsonInput.entry(), :module, C.JsonInput),
      Map.put(C.NavLink.entry(), :module, C.NavLink),
      Map.put(C.FloatingWindow.entry(), :module, C.FloatingWindow)
    ]
    |> Enum.sort_by(&{&1.category, Map.get(&1, :order, 0), &1.name})
  end

  @doc "Entries grouped `[{category, [entry, ...]}, ...]`, categories alphabetical."
  def by_category do
    all()
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  @doc "The entry for a slug, or nil."
  def get(slug), do: Enum.find(all(), &(&1.slug == slug))
end
