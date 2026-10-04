# Mishka widgets (mob_mishka 0.1.3)

A Hex plugin that ships 73 Mob composites (`<MishkaDialog>`, `<MishkaTabs>`, `<MishkaHueSlider>`, `<MishkaSemiCircleProgress>`, `<MishkaAngleSlider>`, …) plus three support modules (`Anchored`, `Color`, `Event`).

Each widget's props, events and examples: `read_doc` its module. Where the front's default gallery shows one, its screen is named below: a worked example (`dyn_read` it).

## What's in it

Seventy-three composites plus three support modules (`Anchored`, `Color`, `Event`). A few of the more useful ones:

| Composite | What it is |
|---|---|
| `<MishkaDialog>` | Modal dialog with confirm/dismiss buttons |
| `<MishkaTabs>` | Tab bar with selectable panels |
| `<MishkaAccordion>` | Expand/collapse panels with open-change events |
| `<MishkaHueSlider>` / `<MishkaAlphaSlider>` | HSL/HSV colour pickers on a canvas |
| `<MishkaSlider>` | Range slider with snap support |
| `<MishkaAngleSlider>` | Circular dial for a 0–360° angle |
| `<MishkaSemiCircleProgress>` | Half-circle gauge |
| `<MishkaLoadingOverlay>` | Full-screen loading indicator |
| `<MishkaSeparator>` / `<MishkaSpoiler>` / `<MishkaVisuallyHidden>` | Layout helpers |
| `<MishkaJsonInput>` | Validating JSON text editor |

## Every composite

- `<MishkaAccordion>` (`MobMishka.Components.MishkaAccordion`): a stack of disclosure items where each header toggles its panel. Gallery: `showcase/components/accordion.ex`.
- `<MishkaActionIcon>` (`MobMishka.Components.MishkaActionIcon`): a compact icon-only button (the ✕ on a card, the ⋯ on a row, the ← in a header). Gallery: `showcase/components/action_icon.ex`.
- `<MishkaAlertDialog>` (`MobMishka.Components.MishkaAlertDialog`): a confirmation modal that demands an explicit choice. Gallery: `showcase/components/alert_dialog.ex`.
- `<MishkaAlphaSlider>` (`MobMishka.Components.MishkaAlphaSlider`): pick an opacity, 0–100, over a real transparency checkerboard. Gallery: `showcase/components/alpha_slider.ex`.
- `<MishkaAnchor>` (`MobMishka.Components.MishkaAnchor`): a link.
- `<MishkaAngleSlider>` (`MobMishka.Components.MishkaAngleSlider`): a circular dial for choosing an angle, 0–360°, with 0° pointing up and the value increasing clockwise. Gallery: `showcase/components/angle_slider.ex`.
- `<MishkaAutocomplete>` (`MobMishka.Components.MishkaAutocomplete`): a text field that suggests completions as you type. Gallery: `showcase/components/autocomplete.ex`.
- `<MishkaAvatar>` (`MobMishka.Components.MishkaAvatar`): an image with a text fallback (typically initials). Gallery: `showcase/components/avatar.ex`.
- `<MishkaBurger>` (`MobMishka.Components.MishkaBurger`): the three-bar navigation button, which folds into an ✕ when open.
- `<MishkaCheckbox>` (`MobMishka.Components.MishkaCheckbox`): a labelled box with checked, unchecked and **indeterminate** states. Gallery: `showcase/components/checkbox.ex`.
- `<MishkaCheckboxGroup>` (`MobMishka.Components.MishkaCheckboxGroup`): a labelled set of checkboxes with an optional tristate "select all" parent. Gallery: `showcase/components/checkbox_group.ex`.
- `<MishkaChip>` (`MobMishka.Components.MishkaChip`): a compact, selectable label (a filter chip). Gallery: `showcase/components/chip.ex`.
- `<MishkaCloseButton>` (`MobMishka.Components.MishkaCloseButton`): the ✕ that dismisses a dialog, a drawer, a toast or a card.
- `<MishkaCode>` (`MobMishka.Components.MishkaCode`): inline code and code blocks. Gallery: `showcase/components/code.ex`.
- `<MishkaCollapsible>` (`MobMishka.Components.MishkaCollapsible`): a trigger that shows and hides one region (the WAI-ARIA disclosure pattern). Gallery: `showcase/components/collapsible.ex`.
- `<MishkaColorInput>` (`MobMishka.Components.MishkaColorInput`): a hex field with a swatch, and a picker that opens beneath it. Gallery: `showcase/components/color_input.ex`.
- `<MishkaColorPicker>` (`MobMishka.Components.MishkaColorPicker`): a saturation/value area over a hue slider. Gallery: `showcase/components/color_picker.ex`.
- `<MishkaColorSwatch>` (`MobMishka.Components.MishkaColorSwatch`): a block of a single colour, optionally selectable. Gallery: `showcase/components/color_swatch.ex`.
- `<MishkaCombobox>` (`MobMishka.Components.MishkaCombobox`): a text field that filters a list of options, single or multiple. Gallery: `showcase/components/combobox.ex`.
- `<MishkaContextMenu>` (`MobMishka.Components.MishkaContextMenu`): the actions for a particular row or object. Gallery: `showcase/components/context_menu.ex`.
- `<MishkaDialog>` (`MobMishka.Components.MishkaDialog`): a centred modal over a dimmed backdrop. Gallery: `showcase/components/dialog.ex`.
- `<MishkaDrawer>` (`MobMishka.Components.MishkaDrawer`): an edge-anchored panel that slides in over a dimmed backdrop, with the gestures the web version is built around: a drag handle, swipe-to-dismiss, snap points, and an edge area you can swipe in from. Gallery: `showcase/components/drawer.ex`.
- `<MishkaEmptyState>` (`MobMishka.Components.MishkaEmptyState`): the placeholder shown when a list has nothing in it: an indicator, a title, supporting text and optional actions. Gallery: `showcase/components/empty_state.ex`.
- `<MishkaField>` (`MobMishka.Components.MishkaField`): a labelled control with a description and validation errors. Gallery: `showcase/components/field.ex`.
- `<MishkaFieldset>` (`MobMishka.Components.MishkaFieldset`): a group of related controls under a legend.
- `<MishkaFloatingIndicator>` (`MobMishka.Components.MishkaFloatingIndicator`): one highlight that marks the active target among several.
- `<MishkaFloatingWindow>` (`MobMishka.Components.MishkaFloatingWindow`): a titled panel that floats over a stage and is dragged by its title bar. Gallery: `showcase/components/floating_window.ex`.
- `<MishkaHighlight>` (`MobMishka.Components.MishkaHighlight`): text with matching substrings marked, as in search results. Gallery: `showcase/components/highlight.ex`.
- `<MishkaHueSlider>` (`MobMishka.Components.MishkaHueSlider`): pick a hue, 0–360°, against a real rainbow track. Gallery: `showcase/components/hue_slider.ex`.
- `<MishkaJsonInput>` (`MobMishka.Components.MishkaJsonInput`): a multi-line field for JSON with a validated error state. Gallery: `showcase/components/json_input.ex`.
- `<MishkaLoadingOverlay>` (`MobMishka.Components.MishkaLoadingOverlay`): a scrim over a region while it is busy. Gallery: `showcase/components/loading_overlay.ex`.
- `<MishkaMark>` (`MobMishka.Components.MishkaMark`): highlighted text, the native equivalent of `<mark>`. Gallery: `showcase/components/mark.ex`.
- `<MishkaMarquee>` (`MobMishka.Components.MishkaMarquee`): content that scrolls past continuously.
- `<MishkaMaskInput>` (`MobMishka.Components.MishkaMaskInput`): a text field that formats itself to a pattern as you type.
- `<MishkaMenu>` (`MobMishka.Components.MishkaMenu`): a list of actions revealed from a trigger. Gallery: `showcase/components/menu.ex`.
- `<MishkaMenubar>` (`MobMishka.Components.MishkaMenubar`): a bar of menus where at most one is open at a time.
- `<MishkaMeter>` (`MobMishka.Components.MishkaMeter`): a scalar gauge for a measurement inside a known range (disk usage, battery level), as distinct from a progress bar, which tracks how far a *task* has got. Gallery: `showcase/components/meter.ex`.
- `<MishkaNavLink>` (`MobMishka.Components.MishkaNavLink`): a navigation row that is either a leaf or a disclosure holding nested links. Gallery: `showcase/components/nav_link.ex`.
- `<MishkaNavigationMenu>` (`MobMishka.Components.MishkaNavigationMenu`): a nav whose expandable items share one content area.
- `<MishkaNumberField>` (`MobMishka.Components.MishkaNumberField`): a numeric input with decrement/increment buttons. Gallery: `showcase/components/number_field.ex`.
- `<MishkaNumberFormatter>` (`MobMishka.Components.MishkaNumberFormatter`): a number rendered with grouping, decimals, prefix and suffix.
- `<MishkaOtpField>` (`MobMishka.Components.MishkaOtpField`): the segmented one-time-code input. Gallery: `showcase/components/otp_field.ex`.
- `<MishkaOverflowList>` (`MobMishka.Components.MishkaOverflowList`): items on one row, with the ones that do not fit collapsed into a `+N` counter. Gallery: `showcase/components/overflow_list.ex`.
- `<MishkaPill>` (`MobMishka.Components.MishkaPill`): a compact label with an optional trailing remove button (a token, a tag, a filter you can dismiss). Gallery: `showcase/components/pill.ex`.
- `<MishkaPillsInput>` (`MobMishka.Components.MishkaPillsInput`): a bordered control holding arbitrary pills beside a text field.
- `<MishkaPopover>` (`MobMishka.Components.MishkaPopover`): a trigger that toggles a panel of arbitrary content beside it. Gallery: `showcase/components/popover.ex`.
- `<MishkaPreviewCard>` (`MobMishka.Components.MishkaPreviewCard`): a trigger you hold, and the card of detail it reveals about the thing it names. Gallery: `showcase/components/preview_card.ex`.
- `<MishkaProgress>` (`MobMishka.Components.MishkaProgress`): a determinate or indeterminate progress bar, optionally labelled and showing its own readout. Gallery: `showcase/components/progress.ex`.
- `<MishkaRadio>` (`MobMishka.Components.MishkaRadio`): one option in a mutually exclusive set. Gallery: `showcase/components/radio.ex`.
- `<MishkaRadioGroup>` (`MobMishka.Components.MishkaRadioGroup`): a labelled set of mutually exclusive options. Gallery: `showcase/components/radio_group.ex`.
- `<MishkaRollingNumber>` (`MobMishka.Components.MishkaRollingNumber`): a number that counts up to its value. Gallery: `showcase/components/rolling_number.ex`.
- `<MishkaScrollArea>` (`MobMishka.Components.MishkaScrollArea`): a bounded region whose content scrolls. Gallery: `showcase/components/scroll_area.ex`.
- `<MishkaScroller>` (`MobMishka.Components.MishkaScroller`): a horizontal rail of items with prev/next controls.
- `<MishkaSegmentedControl>` (`MobMishka.Components.MishkaSegmentedControl`): a joined strip of options where exactly one is always selected. Gallery: `showcase/components/segmented_control.ex`.
- `<MishkaSelect>` (`MobMishka.Components.MishkaSelect`): a trigger showing the current choice, and a list to pick from. Gallery: `showcase/components/select.ex`.
- `<MishkaSemiCircleProgress>` (`MobMishka.Components.MishkaSemiCircleProgress`): a gauge drawn as a half-circle arc. Gallery: `showcase/components/semi_circle_progress.ex`.
- `<MishkaSeparator>` (`MobMishka.Components.MishkaSeparator`): a thematic rule between groups of content, optionally carrying a centred label. Gallery: `showcase/components/separator.ex`.
- `<MishkaSkeleton>` (`MobMishka.Components.MishkaSkeleton`): A placeholder for content that has not arrived — the grey blocks a list shows while it loads. Gallery: `showcase/components/skeleton.ex`.
- `<MishkaSlider>` (`MobMishka.Components.MishkaSlider`): a draggable value along a range, wrapping Mob's native `Slider` widget. Gallery: `showcase/components/slider.ex`.
- `<MishkaSplitter>` (`MobMishka.Components.MishkaSplitter`): two panes sharing an extent, with a control that changes the split. Gallery: `showcase/components/splitter.ex`.
- `<MishkaSpoiler>` (`MobMishka.Components.MishkaSpoiler`): long content that starts collapsed behind a "Show more" control. Gallery: `showcase/components/spoiler.ex`.
- `<MishkaSwitch>` (`MobMishka.Components.MishkaSwitch`): an on/off control. Gallery: `showcase/components/switch.ex`.
- `<MishkaTabs>` (`MobMishka.Components.MishkaTabs`): a tab strip with one visible panel. Gallery: `showcase/components/tabs.ex`.
- `<MishkaTagsInput>` (`MobMishka.Components.MishkaTagsInput`): a bordered control holding removable tokens with a draft field beneath them. Gallery: `showcase/components/tags_input.ex`.
- `<MishkaThemeIcon>` (`MobMishka.Components.MishkaThemeIcon`): a themed container around exactly one icon. Gallery: `showcase/components/theme_icon.ex`.
- `<MishkaToast>` (`MobMishka.Components.MishkaToast`): transient messages stacked at an edge of the screen. Gallery: `showcase/components/toast.ex`.
- `<MishkaToggle>` (`MobMishka.Components.MishkaToggle`): a button that stays pressed, as in a formatting toolbar's bold or italic. Gallery: `showcase/components/toggle.ex`.
- `<MishkaToggleGroup>` (`MobMishka.Components.MishkaToggleGroup`): a row of toggle buttons sharing one selection, in single or multiple mode. Gallery: `showcase/components/toggle_group.ex`.
- `<MishkaToolbar>` (`MobMishka.Components.MishkaToolbar`): a strip of related controls, in groups, with separators between them. Gallery: `showcase/components/toolbar.ex`.
- `<MishkaTooltip>` (`MobMishka.Components.MishkaTooltip`): a short hint about the control it wraps. Gallery: `showcase/components/tooltip.ex`.
- `<MishkaTree>` (`MobMishka.Components.MishkaTree`): hierarchical data as an expandable, selectable, optionally checkable tree. Gallery: `showcase/components/tree.ex`.
- `<MishkaTreeSelect>` (`MobMishka.Components.MishkaTreeSelect`): a trigger showing the current selection, and a tree that opens beneath it. Gallery: `showcase/components/tree_select.ex`.
- `<MishkaVisuallyHidden>` (`MobMishka.Components.MishkaVisuallyHidden`): and the one component in this port that cannot do its job.
