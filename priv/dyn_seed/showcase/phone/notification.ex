defmodule Operator.Dyn.Showcase.Phone.Notification do
  @moduledoc """
  Phone widget: local notifications (`MobNotify.schedule/2`), now or in
  10 s, after asking for the notification permission (Android 13+ and
  iOS ask; older Android answers granted at once). What comes back is
  listed: `{:notification, %{presentation: :foreground}}` when one arrives
  while the app is open, `:tap` when the user opens it (`Mob.Notification`).
  A pending one can be cancelled.

  The answer reaches the screen showing: this one while the front is up,
  the terminal otherwise.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Phone

  def entry do
    %{
      slug: :notification,
      name: "Notification",
      category: "Phone",
      order: 4,
      description: "Send a local notification now or in 10 s; see it arrive and get tapped.",
      api: "MobNotify, Mob.Permissions, Mob.Notification, Mob.Device.open_settings"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: "Send one: the phone asks to allow notifications the first time.",
       access: :unknown,
       # The delay (s) waiting for the permission's answer, if any.
       want: nil,
       sent: 0,
       pending: nil,
       events: []
     )}
  end

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Row fill_width={true}>
          <Button
            text="Notify now"
            background={:primary}
            text_color={:on_primary}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), {:send, 0}}}
          />
          <Spacer size={12} />
          <Button
            text="In 10 s"
            background={:surface_raised}
            text_color={:on_surface}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), {:send, 10}}}
          />
        </Row>
        {cancel_button(@pending)}
        {settings_button(@access)}
        <Spacer size={16} />
        <Text text="What came back" text_size={:sm} text_color={:muted} />
        <Spacer size={4} />
        {event_lines(@events)}
      </Column>
      """
    ])
  end

  defp cancel_button(nil), do: nil

  defp cancel_button(_id) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={12} />
      <Button
        text="Cancel the pending one"
        background={:surface_raised}
        text_color={:on_surface}
        padding={:space_sm}
        fill_width={true}
        on_tap={{self(), :cancel}}
      />
    </Column>
    """
  end

  defp settings_button(:denied) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={12} />
      <Button
        text="Open notification settings"
        background={:surface_raised}
        text_color={:on_surface}
        padding={:space_sm}
        fill_width={true}
        on_tap={{self(), :settings}}
      />
    </Column>
    """
  end

  defp settings_button(_access), do: nil

  defp event_lines([]),
    do: ~MOB(<Text text="Nothing yet." text_size={:sm} text_color={:on_surface} />)

  defp event_lines(events) do
    for line <- events do
      ~MOB(<Text text={line} text_size={:sm} text_color={:on_surface} />)
    end
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  # Ask every time: the answer comes at once when it was decided before.
  defp widget({:tap, {:send, delay}}, socket) do
    socket
    |> Mob.Socket.assign(status: "Checking notification access…", want: delay)
    |> Mob.Permissions.request(:notifications)
  rescue
    _ in [ArgumentError, ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket, :status, "Notifications aren't available on this device.")
  end

  defp widget({:permission, :notifications, :granted}, %{assigns: %{want: delay}} = socket)
       when is_integer(delay) do
    n = socket.assigns.sent + 1
    id = "showcase-#{n}"

    socket =
      MobNotify.schedule(socket,
        id: id,
        title: "Operator",
        body: "Notification #{n} from the component library.",
        delay_seconds: delay,
        data: %{n: n}
      )

    {status, pending} =
      if delay == 0,
        do: {"Sent: look at the top of the screen.", nil},
        else: {"Scheduled for #{delay} s from now: you can leave the app.", id}

    Mob.Socket.assign(socket,
      access: :granted,
      want: nil,
      sent: n,
      status: status,
      pending: pending
    )
  end

  defp widget({:permission, :notifications, :denied}, socket) do
    Mob.Socket.assign(socket,
      access: :denied,
      want: nil,
      status: "Notifications are off for Operator. Turn them on in Settings."
    )
  end

  defp widget({:tap, :cancel}, %{assigns: %{pending: id}} = socket) when is_binary(id) do
    socket
    |> MobNotify.cancel(id)
    |> Mob.Socket.assign(pending: nil, status: "Cancelled #{id}.")
  end

  defp widget({:tap, :settings}, socket) do
    Mob.Device.open_settings(:notifications)
    socket
  end

  # Arrived while the app was open, or opened by the user.
  defp widget({:notification, %{} = n}, socket) do
    what = if n.presentation == :tap, do: "tapped", else: "arrived while open"
    line = "#{now()}  #{n.id || "?"} #{what} (#{n.source})"
    pending = if n.id == socket.assigns.pending, do: nil, else: socket.assigns.pending

    Mob.Socket.assign(socket,
      events: Enum.take([line | socket.assigns.events], 6),
      pending: pending
    )
  end

  defp widget(_message, socket), do: socket

  defp now, do: NaiveDateTime.local_now() |> NaiveDateTime.to_time() |> Time.to_string()
end
