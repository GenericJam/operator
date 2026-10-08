defmodule Operator.Dyn.Showcase.Phone.Location do
  @moduledoc """
  Phone widget: where the phone is. Asks for location access, then gets one
  fix (`MobLocation.get_once/1`) or follows the phone for 30 s
  (`MobLocation.start/2`, stopped by a timer), and shows the coordinates,
  their accuracy, when they came, and a map link to open or copy.

  Android lets the user give only approximate location: the fix then comes
  with an accuracy of a kilometre or more, which is how the screen tells.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Phone

  @follow_ms 30_000

  def entry do
    %{
      slug: :location,
      name: "Location",
      category: "Phone",
      order: 1,
      description: "The phone's coordinates, accuracy and a map link, after asking for access.",
      api: "MobLocation, Mob.Permissions, Mob.Device.open_url, Mob.Clipboard"
    }
  end

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: "Tap a button: the phone asks for location access the first time.",
       access: :unknown,
       # What to do once access is granted: :once or :follow.
       want: nil,
       following: false,
       # Counts follow runs, so a stale stop timer is ignored.
       run: 0,
       fix: nil,
       at: nil
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
            text="Where am I?"
            background={:primary}
            text_color={:on_primary}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :once}}
          />
          <Spacer size={12} />
          <Button
            text={if(@following, do: "Stop following", else: "Follow 30 s")}
            background={:surface_raised}
            text_color={:on_surface}
            padding={:space_sm}
            weight={1}
            on_tap={{self(), :follow}}
          />
        </Row>
        {settings_button(@access)}
        {fix_card(@fix, @at)}
      </Column>
      """
    ])
  end

  # Denied access can only be turned back on in Settings.
  defp settings_button(:denied) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={12} />
      <Button
        text="Open Settings"
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

  defp fix_card(nil, _at), do: nil

  defp fix_card(fix, at) do
    ~MOB"""
    <Column fill_width={true}>
      <Spacer size={16} />
      <Box
        fill_width={true}
        background={:surface}
        padding={:space_md}
        corner_radius={:radius_md}
        border_color={:border}
        border_width={1}
      >
        <Column fill_width={true}>
          <Text
            text={"#{coord(fix.lat)}, #{coord(fix.lon)}"}
            text_size={:xl}
            text_color={:on_surface}
          />
          <Spacer size={6} />
          <Text text={precision(fix[:accuracy])} text_size={:sm} text_color={:muted} />
          <Text
            text={"Altitude #{metres(fix[:altitude])} · at #{at}"}
            text_size={:sm}
            text_color={:muted}
          />
          <Spacer size={12} />
          <Text text={map_url(fix)} text_size={:sm} text_color={:on_surface} />
          <Spacer size={12} />
          <Row fill_width={true}>
            <Button
              text="Open map"
              background={:primary}
              text_color={:on_primary}
              padding={:space_sm}
              weight={1}
              on_tap={{self(), :open_map}}
            />
            <Spacer size={12} />
            <Button
              text="Copy link"
              background={:surface_raised}
              text_color={:on_surface}
              padding={:space_sm}
              weight={1}
              on_tap={{self(), :copy_link}}
            />
          </Row>
        </Column>
      </Box>
    </Column>
    """
  end

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  def terminate(_reason, socket) do
    _ = stop_updates(socket)
    :ok
  end

  # ── the buttons: ask for access first, act on the answer ──

  defp widget({:tap, :once}, socket), do: ask(socket, :once)

  defp widget({:tap, :follow}, %{assigns: %{following: true}} = socket),
    do: stop(socket, "Stopped following.")

  defp widget({:tap, :follow}, socket), do: ask(socket, :follow)

  defp widget({:tap, :settings}, socket) do
    Mob.Device.open_settings(:app)
    socket
  end

  defp widget({:tap, :open_map}, socket) do
    Mob.Device.open_url(map_url(socket.assigns.fix))
    socket
  end

  defp widget({:tap, :copy_link}, socket) do
    socket
    |> Mob.Socket.assign(:status, "Map link copied.")
    |> Mob.Clipboard.put(map_url(socket.assigns.fix))
  end

  # The answer comes every time, also when access was given before.
  defp widget({:permission, :location, :granted}, socket) do
    socket = Mob.Socket.assign(socket, :access, :granted)

    case socket.assigns.want do
      :once ->
        socket
        |> Mob.Socket.assign(status: "Finding you…", want: nil)
        |> MobLocation.get_once()

      :follow ->
        run = socket.assigns.run + 1
        Process.send_after(self(), {:stop_following, run}, @follow_ms)

        socket
        |> Mob.Socket.assign(status: "Following for 30 s…", want: nil, following: true, run: run)
        |> MobLocation.start(accuracy: :high)

      nil ->
        socket
    end
  end

  defp widget({:permission, :location, :denied}, socket), do: denied(socket)

  # ── what MobLocation sends ──

  defp widget({:location, %{lat: _, lon: _} = fix}, socket) do
    status = if socket.assigns.following, do: "Following: updates as you move.", else: "Got it."
    Mob.Socket.assign(socket, fix: fix, at: now(), status: status)
  end

  defp widget({:location, :error, :permission_denied}, socket), do: denied(socket)

  defp widget({:location, :error, reason}, socket) do
    socket
    |> stop_updates()
    |> Mob.Socket.assign(
      :status,
      "No fix (#{inspect(reason)}): location may be off, or there's no signal. " <>
        "On an emulator, set a location in its extended controls."
    )
  end

  defp widget({:stop_following, run}, %{assigns: %{run: run, following: true}} = socket),
    do: stop(socket, "Stopped after 30 s.")

  defp widget(_message, socket), do: socket

  defp ask(socket, want) do
    socket
    |> Mob.Socket.assign(status: "Asking for location access…", want: want)
    |> Mob.Permissions.request(:location)
  rescue
    _ in [ArgumentError, ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket, :status, "Location isn't available on this device.")
  end

  defp denied(socket) do
    socket
    |> stop_updates()
    |> Mob.Socket.assign(
      access: :denied,
      want: nil,
      status: "Location access is off. Turn it on in Settings › Permissions › Location."
    )
  end

  defp stop(socket, status),
    do: socket |> stop_updates() |> Mob.Socket.assign(:status, status)

  defp stop_updates(%{assigns: %{following: true}} = socket),
    do: socket |> MobLocation.stop() |> Mob.Socket.assign(:following, false)

  defp stop_updates(socket), do: socket

  # ── formatting ──

  defp map_url(%{lat: lat, lon: lon}),
    do: "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=16/#{lat}/#{lon}"

  defp coord(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 5)
  defp coord(_), do: "?"

  # Android's approximate location rounds to about 2 km.
  defp precision(acc) when is_number(acc) and acc > 1_000,
    do: "Approximate: within #{metres(acc)} (approximate location, or a network fix)"

  defp precision(acc) when is_number(acc), do: "Precise: within #{metres(acc)}"
  defp precision(_acc), do: "Accuracy unknown"

  defp metres(n) when is_number(n) and n >= 1_000,
    do: "#{:erlang.float_to_binary(n / 1000, decimals: 1)} km"

  defp metres(n) when is_number(n), do: "#{round(n)} m"
  defp metres(_), do: "?"

  defp now, do: NaiveDateTime.local_now() |> NaiveDateTime.to_time() |> Time.to_string()
end
