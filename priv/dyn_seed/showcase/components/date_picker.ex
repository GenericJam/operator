defmodule Operator.Dyn.Showcase.Components.DatePicker do
  @moduledoc """
  A month calendar to pick a date with, built from plain Mob nodes (neither
  mob nor Mishka has a date picker), and its gallery page.

  The widget is two functions another screen calls, stateless like every
  Mishka component: `calendar/3` draws the month and `update/3` applies a
  tap to the screen's value, so the screen's `handle_info/2` is one line:

      alias Operator.Dyn.Showcase.Components.DatePicker

      # render/1
      {DatePicker.calendar(@date, :date)}

      def handle_info({:tap, {:date, event}}, socket),
        do: {:noreply, Mob.Socket.update(socket, :date, &DatePicker.update(&1, event))}

  The value is either a `Date` (always picked; ‹ › move it a month) or the
  map `new/1` returns, `%{selected: Date | nil, month: Date}` (‹ › only page
  through months; nothing picked until a day is tapped). A tap sends
  `{:tap, {tag, event}}`: `{:day, %Date{}}`, `:prev` or `:next`.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Example
  alias Operator.Dyn.Showcase.Page

  @weekdays ~w(Mo Tu We Th Fr Sa Su)

  def entry do
    %{
      slug: :date_picker,
      name: "Date picker",
      category: "Forms",
      order: 19,
      description: "A month calendar to pick a day from, with bounds and a week start."
    }
  end

  # ── the widget ──

  @doc """
  A picker value that browses months without picking: `selected` is
  `date` (nil for nothing yet) and the month shown is `date`'s, or today's.
  """
  def new(date \\ nil), do: %{selected: date, month: first_of_month(date || today())}

  @doc """
  The month grid for `value` (a `Date` or a `new/1` map); taps arrive as
  `{:tap, {tag, event}}`. Options: `min:` / `max:` (`Date`s; days outside
  are dimmed and can't be tapped), `first_day:` (`:monday`, the default, or
  `:sunday`), `today:` (the day outlined; the phone's date by default).
  """
  def calendar(value, tag, opts \\ []) do
    {selected, month} = view(value)
    today = Keyword.get_lazy(opts, :today, &today/0)
    first_day = Keyword.get(opts, :first_day, :monday)
    {min, max} = {opts[:min], opts[:max]}

    can_prev = min == nil or Date.compare(Date.add(month, -1), min) != :lt
    can_next = max == nil or Date.compare(Date.shift(month, month: 1), max) != :gt

    header =
      row([
        arrow("‹", can_prev && {tag, :prev}),
        %{
          type: :text,
          props: %{
            text: Calendar.strftime(month, "%B %Y"),
            text_size: :lg,
            font_weight: "bold",
            text_color: :on_surface,
            text_align: "center",
            weight: 1
          },
          children: []
        },
        arrow("›", can_next && {tag, :next})
      ])

    lead = Date.day_of_week(month, first_day) - 1
    days = Enum.map(0..(Date.days_in_month(month) - 1), &Date.add(month, &1))

    weeks =
      (List.duplicate(nil, lead) ++ days)
      |> Enum.chunk_every(7, 7, List.duplicate(nil, 6))
      |> Enum.map(fn week ->
        row(Enum.map(week, &day_cell(&1, tag, selected, today, min, max)))
      end)

    %{
      type: :box,
      props: %{
        background: :surface,
        border_color: :border,
        border_width: 1,
        corner_radius: :radius_md,
        padding: :space_sm,
        fill_width: true
      },
      children: [
        %{
          type: :column,
          props: %{fill_width: true, gap: 4},
          children: [header, weekday_row(first_day) | weeks]
        }
      ]
    }
  end

  @doc """
  `value` after the event a tap carried. Pure. With a `Date`, ‹ › move it a
  month (the 31st becomes the month's last day); `min:` / `max:` clamp it.
  """
  def update(value, event, opts \\ [])

  def update(%Date{}, {:day, %Date{} = day}, _opts), do: day
  def update(%Date{} = date, :prev, opts), do: clamp(Date.shift(date, month: -1), opts)
  def update(%Date{} = date, :next, opts), do: clamp(Date.shift(date, month: 1), opts)

  def update(%{selected: _, month: _} = state, {:day, %Date{} = day}, _opts),
    do: %{state | selected: day, month: first_of_month(day)}

  def update(%{month: month} = state, :prev, _opts),
    do: %{state | month: Date.shift(month, month: -1)}

  def update(%{month: month} = state, :next, _opts),
    do: %{state | month: Date.shift(month, month: 1)}

  def update(value, _event, _opts), do: value

  @doc "A picked date as people read it: \"Tue 6 Oct 2026\" (nil: \"No date\")."
  def label(nil), do: "No date"
  def label(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b %Y")
  def label(%{selected: date}), do: label(date)

  defp view(%Date{} = date), do: {date, first_of_month(date)}
  defp view(%{selected: selected, month: month}), do: {selected, first_of_month(month)}

  defp first_of_month(date), do: Date.beginning_of_month(date)

  # The phone's own calendar day, as the BEAM's local time sees it.
  defp today, do: NaiveDateTime.to_date(NaiveDateTime.local_now())

  defp clamp(date, opts) do
    min = opts[:min]
    max = opts[:max]

    cond do
      min && Date.compare(date, min) == :lt -> min
      max && Date.compare(date, max) == :gt -> max
      true -> date
    end
  end

  defp weekday_row(first_day) do
    names = if first_day == :sunday, do: ["Su" | Enum.take(@weekdays, 6)], else: @weekdays

    row(
      Enum.map(names, fn name ->
        %{
          type: :text,
          props: %{
            text: name,
            text_size: :sm,
            text_color: :muted,
            text_align: "center",
            weight: 1
          },
          children: []
        }
      end)
    )
  end

  defp arrow(symbol, event) do
    props = %{
      width: 44,
      padding: :space_sm,
      corner_radius: :radius_pill,
      background: :surface_raised
    }

    {props, color} =
      if event,
        do: {Map.put(props, :on_tap, {self(), event}), :on_surface},
        else: {props, :muted}

    %{type: :box, props: props, children: [centered(symbol, color, :lg, "regular")]}
  end

  defp day_cell(nil, _tag, _selected, _today, _min, _max),
    do: %{type: :box, props: %{weight: 1, height: 40}, children: []}

  defp day_cell(day, tag, selected, today, min, max) do
    enabled =
      (min == nil or Date.compare(day, min) != :lt) and
        (max == nil or Date.compare(day, max) != :gt)

    {style, color, weight} =
      cond do
        day == selected -> {%{background: :primary}, :on_primary, "bold"}
        not enabled -> {%{}, :muted, "regular"}
        day == today -> {%{border_color: :primary, border_width: 1}, :primary, "bold"}
        true -> {%{}, :on_surface, "regular"}
      end

    props =
      Map.merge(
        %{fill_width: true, height: 40, padding: :space_sm, corner_radius: :radius_pill},
        style
      )

    props = if enabled, do: Map.put(props, :on_tap, {self(), {tag, {:day, day}}}), else: props

    %{
      type: :box,
      props: %{weight: 1, padding: 2},
      children: [
        %{type: :box, props: props, children: [centered("#{day.day}", color, :base, weight)]}
      ]
    }
  end

  defp centered(text, color, size, weight) do
    %{
      type: :text,
      props: %{
        text: text,
        text_size: size,
        text_color: color,
        font_weight: weight,
        text_align: "center",
        fill_width: true
      },
      children: []
    }
  end

  defp row(children), do: %{type: :row, props: %{fill_width: true}, children: children}

  # ── the gallery page ──

  def mount(socket) do
    today = today()

    socket
    |> Mob.Socket.assign(:dp_today, today)
    |> Mob.Socket.assign(:dp_date, today)
    |> Mob.Socket.assign(:dp_trip, new())
    |> Mob.Socket.assign(:dp_booking, today)
    |> Mob.Socket.assign(:dp_field, nil)
    |> Mob.Socket.assign(:dp_field_open, false)
  end

  def examples do
    [
      %Example{
        title: "Pick a date",
        description: "The value is a Date: always picked, ‹ › move it a month.",
        code: ~S"""
        {DatePicker.calendar(@date, :date)}

        alias Operator.Dyn.Showcase.Components.DatePicker

        def mount(_params, _session, socket),
          do: {:ok, Mob.Socket.assign(socket, :date, Date.utc_today())}

        def handle_info({:tap, {:date, event}}, socket),
          do: {:noreply, Mob.Socket.update(socket, :date, &DatePicker.update(&1, event))}
        """,
        render: fn assigns ->
          ~MOB"""
          <Column fill_width={true}>
            {calendar(@dp_date, :dp_date)}
            <Spacer size={8} />
            <Text text={"Picked: " <> label(@dp_date)} text_size={:base} text_color={:on_surface} />
          </Column>
          """
        end
      },
      %Example{
        title: "Nothing picked yet",
        description:
          "new/1 makes a value that pages through months on its own; selected starts nil.",
        code: ~S"""
        assign(socket, :trip, DatePicker.new())

        {DatePicker.calendar(@trip, :trip)}
        <Text text={DatePicker.label(@trip)} />

        # @trip.selected is the Date, once one is tapped.
        def handle_info({:tap, {:trip, event}}, socket),
          do: {:noreply, Mob.Socket.update(socket, :trip, &DatePicker.update(&1, event))}
        """,
        render: fn assigns ->
          ~MOB"""
          <Column fill_width={true}>
            {calendar(@dp_trip, :dp_trip)}
            <Spacer size={8} />
            <Text text={label(@dp_trip)} text_size={:base} text_color={:on_surface} />
          </Column>
          """
        end
      },
      %Example{
        title: "Bounds and Sunday first",
        description:
          "min and max dim the days outside and stop the arrows at the edge; " <>
            "update/3 takes the same bounds so ‹ › never leave them.",
        code: ~S"""
        bounds = [min: Date.utc_today(), max: Date.add(Date.utc_today(), 60)]

        {DatePicker.calendar(@booking, :booking, [first_day: :sunday] ++ bounds)}

        def handle_info({:tap, {:booking, event}}, socket) do
          {:noreply,
           Mob.Socket.update(socket, :booking, &DatePicker.update(&1, event, bounds))}
        end
        """,
        render: fn assigns ->
          ~MOB"""
          <Column fill_width={true}>
            {calendar(@dp_booking, :dp_booking, [first_day: :sunday] ++ bounds(@dp_today))}
            <Spacer size={8} />
            <Text text={"Booked: " <> label(@dp_booking)} text_size={:base} text_color={:on_surface} />
          </Column>
          """
        end
      },
      %Example{
        title: "As a field",
        description: "A button shows the date; the calendar opens under it and closes on a pick.",
        code: ~S"""
        <Button text={DatePicker.label(@due)} on_tap={{self(), :due_open}}
                background={:surface_raised} text_color={:on_surface} />
        <Column :if={@due_open} fill_width={true}>
          {DatePicker.calendar(@due || Date.utc_today(), :due)}
        </Column>

        def handle_info({:tap, :due_open}, socket),
          do: {:noreply, Mob.Socket.update(socket, :due_open, &(!&1))}

        def handle_info({:tap, {:due, {:day, day}}}, socket),
          do: {:noreply, Mob.Socket.assign(socket, due: day, due_open: false)}

        def handle_info({:tap, {:due, event}}, socket) do
          due = DatePicker.update(socket.assigns.due || Date.utc_today(), event)
          {:noreply, Mob.Socket.assign(socket, :due, due)}
        end
        """,
        render: fn assigns ->
          ~MOB"""
          <Column fill_width={true}>
            <Button
              text={"📅  " <> label(@dp_field)}
              on_tap={{self(), :dp_field_open}}
              background={:surface_raised}
              text_color={:on_surface}
            />
            <Column :if={@dp_field_open} fill_width={true}>
              <Spacer size={8} />
              {calendar(@dp_field || @dp_today, :dp_field)}
            </Column>
          </Column>
          """
        end
      }
    ]
  end

  def props do
    [
      %{
        name: "calendar(value, tag, opts)",
        type: "node",
        default: "—",
        description:
          "The month grid. value is a Date or a new/1 map; taps send {:tap, {tag, event}}."
      },
      %{
        name: "event",
        type: "{:day, Date} | :prev | :next",
        default: "—",
        description: "What a tap carries: a day, or a month back / forward."
      },
      %{
        name: "update(value, event, opts)",
        type: "helper",
        default: "—",
        description: "The value after event. Pure; min/max clamp a Date moved by ‹ ›."
      },
      %{
        name: "new(date)",
        type: "helper",
        default: "nil",
        description: "%{selected: date, month: …}: months page on their own, nothing picked yet."
      },
      %{
        name: "label(value)",
        type: "helper",
        default: "—",
        description: "\"Tue 6 Oct 2026\", or \"No date\"."
      },
      %{
        name: "min / max",
        type: "Date",
        default: "nil",
        description: "Days outside are dimmed and can't be tapped; the arrows stop at the edge."
      },
      %{
        name: "first_day",
        type: ":monday | :sunday",
        default: ":monday",
        description: "The week's first column."
      },
      %{
        name: "today",
        type: "Date",
        default: "the phone's date",
        description: "The day outlined."
      }
    ]
  end

  def handle({:dp_field, {:day, day}}, socket),
    do: Mob.Socket.assign(socket, dp_field: day, dp_field_open: false)

  def handle({:dp_field, event}, socket) do
    value = update(socket.assigns.dp_field || socket.assigns.dp_today, event)
    Mob.Socket.assign(socket, :dp_field, value)
  end

  def handle(:dp_field_open, socket), do: Mob.Socket.update(socket, :dp_field_open, &(!&1))

  def handle({:dp_booking, event}, socket),
    do:
      Mob.Socket.update(socket, :dp_booking, &update(&1, event, bounds(socket.assigns.dp_today)))

  def handle({key, event}, socket) when key in [:dp_date, :dp_trip],
    do: Mob.Socket.update(socket, key, &update(&1, event))

  def handle(_tag, socket), do: socket

  defp bounds(today), do: [min: today, max: Date.add(today, 60)]

  def card_preview do
    ~MOB"""
    <Column fill_width={true}>
      <Box width={90} height={8} background={:surface_raised} corner_radius={:radius_pill} />
      <Spacer size={8} />
      {preview_week(nil)}
      <Spacer size={6} />
      {preview_week(3)}
    </Column>
    """
  end

  defp preview_week(picked) do
    dots =
      for i <- 0..4 do
        background = if i == picked, do: :primary, else: :surface_raised

        %{
          type: :box,
          props: %{width: 14, height: 14, background: background, corner_radius: :radius_pill},
          children: []
        }
      end

    %{type: :row, props: %{gap: 6}, children: dots}
  end

  # ── screen ──

  def mount(_params, _session, socket), do: {:ok, mount(socket)}

  def render(assigns),
    do: Page.render(entry(), examples(), props(), overlay(assigns), assigns)

  def handle_info(message, socket),
    do: {:noreply, Page.handle_info(message, socket, &handle/2, &handle_change/3)}

  defp handle_change(_tag, _value, socket), do: socket

  defp overlay(_assigns), do: nil
end
