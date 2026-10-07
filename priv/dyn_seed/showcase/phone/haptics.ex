defmodule Operator.Dyn.Showcase.Phone.Haptics do
  @moduledoc """
  Phone widget: one button per haptic feedback kind of `Mob.Haptic.trigger/2`
  (impacts: light, medium, heavy; notifications: success, warning, error).
  No permission. Emulators and phones without a vibration motor feel
  nothing; the call still succeeds.
  """
  use Mob.Screen

  alias Operator.Dyn.Showcase.Kit
  alias Operator.Dyn.Showcase.Phone

  @kinds [
    light: "Light",
    medium: "Medium",
    heavy: "Heavy",
    success: "Success",
    warning: "Warning",
    error: "Error"
  ]

  def entry do
    %{
      slug: :haptics,
      name: "Haptics",
      category: "Phone",
      order: 5,
      description:
        "Feel each haptic feedback kind: light, medium, heavy, success, warning, error.",
      api: "Mob.Haptic"
    }
  end

  def mount(_params, _session, socket),
    do: {:ok, Mob.Socket.assign(socket, :status, "Tap one and feel the phone.")}

  def render(assigns) do
    Phone.page(entry(), [
      ~MOB"""
      <Column fill_width={true}>
        <Text text={@status} text_size={:base} text_color={:on_surface} />
        <Spacer size={12} />
        <Text
          text="Impacts: a tap of some weight, for presses and snaps."
          text_size={:sm}
          text_color={:muted}
        />
        <Spacer size={8} />
        {buttons([:light, :medium, :heavy])}
        <Spacer size={16} />
        <Text text="Notifications: the outcome of an action." text_size={:sm} text_color={:muted} />
        <Spacer size={8} />
        {buttons([:success, :warning, :error])}
      </Column>
      """
    ])
  end

  defp buttons(kinds),
    do: kinds |> Enum.map(&Kit.compact_button(@kinds[&1], {:haptic, &1})) |> Kit.grid()

  def handle_info(message, socket) do
    case Phone.handle(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :pass -> {:noreply, widget(message, socket)}
    end
  end

  defp widget({:tap, {:haptic, kind}}, socket) do
    socket
    |> Mob.Haptic.trigger(kind)
    |> Mob.Socket.assign(:status, "Mob.Haptic.trigger(socket, #{inspect(kind)})")
  rescue
    _ in [ErlangError, UndefinedFunctionError] ->
      Mob.Socket.assign(socket, :status, "No haptics on this device.")
  end

  defp widget(_message, socket), do: socket
end
