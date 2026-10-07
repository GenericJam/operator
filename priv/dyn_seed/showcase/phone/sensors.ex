defmodule Operator.Dyn.Showcase.Phone.Sensors do
  @moduledoc """
  Phone widget: live sensor readings. `Mob.Motion` streams the
  accelerometer, gyroscope and compass heading; `MobSensors` streams the
  environment sensors the phone has (light, pressure, proximity, humidity,
  temperature) and the step counter, which needs the physical activity
  permission. Everything stops on Stop, or by itself after 60 s.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Phone

  @run_ms 60_000
  # The MobSensors types shown, with their labels and units, in this order.
  @extra [
    light: {"Light", "lx"},
    pressure: {"Pressure", "hPa"},
    proximity: {"Proximity", "cm"},
    relative_humidity: {"Humidity", "%"},
    ambient_temperature: {"Temperature", "°C"},
    step_counter: {"Steps", "steps"}
  ]

  def entry do
    %{
      slug: :sensors,
      name: "Sensors",
      category: "Phone",
      order: 2,
      description: "Live motion, compass, light, pressure, proximity and steps, for 60 s.",
      api: "Mob.Motion, MobSensors, Mob.Permissions"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: "Start reads every sensor for 60 s.",
       running: false,
       # Counts runs, so a stale stop timer is ignored.
       run: 0,
       motion: nil,
       # MobSensors type => latest values, or an error text.
       readings: %{},
       # The MobSensors types streaming now.
       streams: [],
       # The phone's sensors, from MobSensors.list/0.
       present: []
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Button
          text={if(@running, do: "Stop", else: "Start")}
          background={:primary}
          text_color={:on_primary}
          padding={:space_sm}
          fill_width={true}
          on_tap={{self(), :toggle}}
        />
        <Spacer size={16} />
        {card("Motion", motion_rows(@motion))}
        <Spacer size={12} />
        {card("Environment and steps", extra_rows(@readings, @present))}
      </Column>
      """
    ])
  end

  defp card(title, rows) do
    ~MOB"""
    <Box
      fill_width={true}
      background={:surface}
      padding={:space_md}
      corner_radius={:radius_md}
      border_color={:border}
      border_width={1}
    >
      <Column fill_width={true}>
        <Text text={title} text_size={:lg} text_color={:on_surface} />
        <Spacer size={8} />
        {rows}
      </Column>
    </Box>
    """
  end

  defp row(label, value) do
    ~MOB"""
    <Row fill_width={true}>
      <Text text={label} text_size={:sm} text_color={:muted} weight={1} />
      <Text text={value} text_size={:sm} text_color={:on_surface} weight={2} />
    </Row>
    """
  end

  defp motion_rows(nil), do: [row("Waiting", "start to read")]

  defp motion_rows(m) do
    [
      row("Accelerometer", vector(m[:accel], "m/s²")),
      row("Gyroscope", vector(m[:gyro], "rad/s")),
      row("Compass", heading(m[:heading]))
    ]
  end

  defp extra_rows(_readings, []), do: [row("Waiting", "start to list them")]

  defp extra_rows(readings, present) do
    for {type, {label, unit}} <- @extra do
      value =
        cond do
          type not in present -> "not on this phone"
          true -> reading(Map.get(readings, type), unit)
        end

      row(label, value)
    end
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:tap, :toggle}, %{assigns: %{running: true}} = socket),
    do: stop(socket, "Stopped.")

  defp widget({:tap, :toggle}, socket), do: start(socket)

  defp widget({:stop, run}, %{assigns: %{run: run, running: true}} = socket),
    do: stop(socket, "Stopped after 60 s. Start again for more.")

  defp widget({:motion, motion}, %{assigns: %{running: true}} = socket),
    do: Mob.Socket.assign(socket, :motion, motion)

  defp widget({:mob_sensors, :reading, type, %{values: values}}, socket) do
    if type in socket.assigns.streams,
      do: put_reading(socket, type, values),
      else: socket
  end

  defp widget({:mob_sensors, :error, type, reason}, socket) do
    socket
    |> put_reading(type, "error: #{inspect(reason)}")
    |> Mob.Socket.assign(:streams, List.delete(socket.assigns.streams, type))
  end

  # The step counter streams once the user allows physical activity access.
  defp widget(
         {:permission, :activity_recognition, :granted},
         %{assigns: %{running: true}} = socket
       ),
       do: stream(socket, :step_counter)

  defp widget({:permission, :activity_recognition, :denied}, socket),
    do: put_reading(socket, :step_counter, "no access: allow Physical activity in Settings")

  defp widget(_message, socket), do: socket

  defp start(socket) do
    run = socket.assigns.run + 1
    Process.send_after(self(), {:stop, run}, @run_ms)

    socket =
      Mob.Socket.assign(socket,
        running: true,
        run: run,
        status: "Reading… stops by itself after 60 s.",
        motion: nil,
        readings: %{},
        streams: []
      )

    Mob.Motion.start(socket, sensors: [:accelerometer, :gyro, :magnetometer], interval_ms: 200)

    present = for %{type: type} <- MobSensors.list(), Keyword.has_key?(@extra, type), do: type
    socket = Mob.Socket.assign(socket, :present, present)

    socket =
      present
      |> List.delete(:step_counter)
      |> Enum.reduce(socket, &stream(&2, &1))

    if :step_counter in present,
      do: Mob.Permissions.request(socket, :activity_recognition),
      else: socket
  rescue
    _ in [ArgumentError, ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket,
        running: false,
        status: "Sensors aren't available on this device."
      )
  end

  defp stream(socket, type) do
    case MobSensors.start(type, interval_ms: 500) do
      :ok ->
        Mob.Socket.assign(socket, :streams, [type | socket.assigns.streams])

      {:error, reason} ->
        put_reading(socket, type, "can't start: #{inspect(reason)}")
    end
  end

  defp stop(socket, status) do
    Mob.Motion.stop(socket)
    Enum.each(socket.assigns.streams, &MobSensors.stop/1)
    Mob.Socket.assign(socket, running: false, streams: [], status: status)
  end

  defp put_reading(socket, type, value),
    do: Mob.Socket.assign(socket, :readings, Map.put(socket.assigns.readings, type, value))

  # ── formatting ──

  defp vector({x, y, z}, unit), do: "#{num(x)}  #{num(y)}  #{num(z)} #{unit}"
  defp vector(_, _unit), do: "—"

  defp heading(deg) when is_number(deg), do: "#{round(deg)}° from magnetic north"
  defp heading(_), do: "no compass reading (wave the phone in a figure 8)"

  defp reading(nil, _unit), do: "waiting…"
  defp reading([value | _], unit), do: "#{num(value)} #{unit}"
  defp reading(text, _unit) when is_binary(text), do: text
  defp reading(_values, _unit), do: "—"

  defp num(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp num(_), do: "?"
end
