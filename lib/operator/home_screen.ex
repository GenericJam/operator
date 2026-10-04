defmodule Operator.HomeScreen do
  @moduledoc """
  Diagnostics (and the first screen while no model provider is signed in):
  the provider sign-ins (`Operator.Auth`; signing in is `/login anthropic`
  or `/login openai` in the chat, or scanning a login QR minted on the Mac),
  today's model spend against the daily cost cap (editable), code updates
  from the Mac (`Operator.Deliver`: the update server, the code running,
  the last check, "Check for updates now"), the agent stack's status, and
  the Dyn layer: its current generation, sample proposals that run the
  self-modification pipeline on the phone, its screens, and the way to the
  rescue screen. The first sign-in hands over to `Operator.ChatScreen`, and
  so does an `operator://` link scanned with another app while this screen
  shows (the chat handles it).
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.Core.Budget
  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Samples
  alias Operator.Core.Front
  alias Operator.Core.Settings
  alias Operator.Deliver
  alias Operator.Toggle

  def mount(params, _session, socket) do
    # The theme (terminal font token included) is installed once at boot by
    # Operator.Core.Term.install/0.
    :ok = Auth.subscribe()
    Dyn.subscribe()
    data_dir = Map.get(params, :data_dir) || Operator.Paths.data_dir()

    {:ok,
     socket
     |> Mob.Socket.assign(auth: Auth.status(), last: boot_line())
     |> Mob.Socket.assign(data_dir: data_dir, cap_draft: "", updates: nil, update_note: nil)
     |> spend()
     |> dyn()
     |> refresh_updates()}
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        {Toggle.title("Operator")}
        <Text text={stack_line()} text_size={:sm} text_color={:muted} />
        <Spacer size={16} />
        <Text text="Model sign-in" text_size={:sm} text_color={:muted} />
        {auth_section(assigns.auth)}
        <Text
          text="Sign in from the chat: type /login anthropic (Claude Pro/Max) or /login openai (ChatGPT Plus/Pro)."
          text_size={:sm}
          text_color={:muted}
        />
        <Spacer size={8} />
        {button("Open the chat", :open_chat)}
        <Spacer size={8} />
        {button("Scan QR", :scan_qr)}
        <Spacer size={24} />
        <Text text="Spending" text_size={:sm} text_color={:muted} />
        <Text text={assigns.spend_line} text_color={:primary} />
        <Spacer size={8} />
        {cap_field(assigns.cap_draft)}
        <Spacer size={8} />
        {button("Save daily cap", :save_cap)}
        <Spacer size={24} />
        <Text text="Code updates from the Mac" text_size={:sm} text_color={:muted} />
        {updates_section(assigns)}
        <Spacer size={8} />
        {button("Check for updates now", :check_updates)}
        <Spacer size={24} />
        <Text text="Dyn layer (self-modification)" text_size={:sm} text_color={:muted} />
        <Text text={assigns.dyn_line} text_color={:primary} />
        <Text text={assigns.last} text_size={:sm} text_color={:muted} />
        <Spacer size={8} />
        {button("Propose sample: Hello", {:propose, "hello"})}
        <Spacer size={8} />
        {button("Propose sample: Checklist (~200 lines)", {:propose, "checklist"})}
        <Spacer size={8} />
        {button("Activate the proposal", :activate)}
        <Spacer size={8} />
        {button("Rescue: generations, diffs, crash log", :rescue)}
        <Spacer size={16} />
        {dyn_section(assigns.dyn)}
      </Column>
    </Scroll>
    """
  end

  # ── sign-in ──

  def handle_info({:tap, :open_chat}, socket),
    do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen)}

  def handle_info({:tap, :scan_qr}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.LoginScanScreen)}

  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen, %{link: link})}

  # The first sign-in (a scanned QR, say) goes on to the chat.
  def handle_info({:operator_auth, :changed}, socket) do
    was = signed_in?(socket.assigns.auth)
    socket = Mob.Socket.assign(socket, :auth, Auth.status())

    if not was and signed_in?(socket.assigns.auth),
      do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen)},
      else: {:noreply, socket}
  end

  # ── spending ──

  def handle_info({:change, :cap, value}, socket) when is_binary(value),
    do: {:noreply, Mob.Socket.assign(socket, :cap_draft, value)}

  def handle_info({:tap, :save_cap}, socket) do
    case Float.parse(String.trim(socket.assigns.cap_draft)) do
      {cap, ""} when cap >= 0 ->
        :ok = Settings.put_daily_cap(cap, socket.assigns.data_dir)
        {:noreply, socket |> Mob.Socket.assign(cap_draft: "") |> spend()}

      _ ->
        {:noreply,
         Mob.Socket.assign(
           socket,
           :spend_line,
           "Not a dollar amount: #{socket.assigns.cap_draft}"
         )}
    end
  end

  # ── code updates (Operator.Deliver) ──

  # Checks and the state both read the network or stored code: off the
  # screen process, the answer comes back as a message.
  def handle_info({:tap, :check_updates}, socket) do
    screen = self()
    {:ok, _} = Task.start(fn -> send(screen, {:operator_deliver, :checked, Deliver.check()}) end)
    {:noreply, Mob.Socket.assign(socket, :update_note, "Checking for updates…")}
  end

  def handle_info({:operator_deliver, :checked, result}, socket) do
    note = "This check: " <> Deliver.describe(result)
    {:noreply, socket |> Mob.Socket.assign(:update_note, note) |> refresh_updates()}
  end

  def handle_info({:operator_deliver, :status, status}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :updates, status)}

  def handle_info({:tap, :dismiss_rollback}, socket) do
    :ok = Deliver.dismiss_rollback()
    {:noreply, refresh_updates(socket)}
  end

  # ── the Dyn layer ──

  # Stages the sample over the current generation's sources and proposes it:
  # check, compile, selftest, as the agent's changes go.
  def handle_info({:tap, {:propose, name}}, socket) do
    {path, source} = Samples.get(name)

    line =
      with :ok <- Dyn.stage_reset(),
           :ok <- Dyn.stage_put(path, source) do
        case Dyn.propose("Sample screen #{name}") do
          {:ok, p} ->
            "G#{p.n} proposed: compiled in #{p.compile_ms} ms, #{length(p.selftests)} selftests passed"

          {:error, %{stage: stage, reason: reason}} ->
            "rejected at #{stage}: #{String.slice(reason, 0, 300)}"

          {:error, other} ->
            "not proposed: #{inspect(other)}"
        end
      else
        {:error, e} -> "can't stage #{path}: #{inspect(e)}"
      end

    {:noreply, socket |> Mob.Socket.assign(:last, line) |> dyn()}
  end

  def handle_info({:tap, :activate}, socket) do
    line =
      case Dyn.status() do
        %{pending: nil} ->
          "nothing proposed"

        %{pending: n} ->
          with {:ok, token} <- Dyn.request_approval({:activate, n}),
               {:ok, gen} <- Dyn.activate(n, token) do
            "G#{gen.n} active, on probation"
          else
            {:error, :approval_required} ->
              "G#{n} waits for approval: approve it in the chat"

            {:error, e} ->
              "G#{n} not activated: #{inspect(e) |> String.slice(0, 300)}"
          end
      end

    {:noreply, socket |> Mob.Socket.assign(:last, line) |> dyn()}
  end

  def handle_info({:tap, :rescue}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.RescueScreen)}

  # In the front, under the toggle, like every front screen.
  def handle_info({:tap, {:open, name}}, socket) do
    _ = Front.open(name)
    {:noreply, Toggle.to_front(socket)}
  end

  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

  def handle_info({:operator_dyn, _event}, socket), do: {:noreply, dyn(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── helpers ──

  defp button(label, tag) do
    tap = {self(), tag}
    ~MOB(<Button
  text={label}
  background={:primary}
  text_color={:on_primary}
  padding={:space_sm}
  fill_width={true}
  on_tap={tap}
/>)
  end

  defp cap_field(draft) do
    %{
      type: :text_field,
      props: %{
        value: draft,
        placeholder: "new daily cap in dollars, e.g. 2.50",
        fill_width: true,
        on_change: {self(), :cap}
      },
      children: []
    }
  end

  defp refresh_updates(socket) do
    screen = self()
    {:ok, _} = Task.start(fn -> send(screen, {:operator_deliver, :status, Deliver.status()}) end)
    socket
  end

  defp updates_section(%{updates: nil}), do: ~MOB(<Text text="…" text_color={:muted} />)

  defp updates_section(%{updates: status, update_note: note}) do
    lines =
      for line <- Deliver.status_lines(status) ++ List.wrap(note),
          do: ~MOB(<Text text={line} text_color={:primary} />)

    dismiss =
      if status.rollback,
        do: [button("Dismiss the rollback notice", :dismiss_rollback)],
        else: []

    %{type: :column, props: %{fill_width: true}, children: lines ++ dismiss}
  end

  defp spend(socket) do
    dir = socket.assigns.data_dir
    spent = :erlang.float_to_binary(Budget.spent(dir), decimals: 4)
    cap = :erlang.float_to_binary(Settings.daily_cap(dir), decimals: 2)
    Mob.Socket.assign(socket, :spend_line, "Today $#{spent} of the $#{cap} daily cap")
  end

  defp dyn_section([]), do: ~MOB(<Text text="No front screens" text_color={:muted} />)

  # One tappable line per front screen (the default front alone has 67).
  defp dyn_section(screens) do
    rows =
      for {name, _mod} <- screens do
        %{
          type: :text,
          props: %{
            text: "▸ " <> name,
            text_size: :sm,
            text_color: :primary,
            padding: 6,
            fill_width: true,
            on_tap: {self(), {:open, name}}
          },
          children: []
        }
      end

    %{type: :column, props: %{fill_width: true}, children: rows}
  end

  defp dyn(socket),
    do: Mob.Socket.assign(socket, dyn_line: dyn_line(Dyn.status()), dyn: Dyn.screens())

  defp dyn_line(%{mode: :safe, generation: n}),
    do: "SAFE MODE: launches kept failing, no Dyn code loaded (generation #{n} is current)"

  defp dyn_line(%{mode: :off}), do: "not started"
  defp dyn_line(%{generation: 0, pending: nil}), do: "no generation yet"

  defp dyn_line(%{generation: n, status: status, pending: pending}),
    do: "generation #{n} (#{status})" <> if(pending, do: " · G#{pending} proposed", else: "")

  defp stack_line do
    apps = Operator.Diag.apps()
    down = for {app, false} <- apps, app not in [:mnesia, :compiler], do: app
    if down == [], do: "agent stack: all apps running", else: "agent stack DOWN: #{inspect(down)}"
  end

  defp auth_section(status) do
    lines =
      for provider <- Auth.providers() do
        text = "#{Auth.label(provider)}: #{auth_line(status[provider])}"
        ~MOB(<Text text={text} text_color={:primary} />)
      end

    %{type: :column, props: %{fill_width: true}, children: lines}
  end

  defp auth_line(%{signed_in: false}), do: "not signed in"

  defp auth_line(%{email: email, expires: expires}) do
    who = if email, do: "signed in as #{email}", else: "signed in"
    minutes = div(expires - System.os_time(:millisecond), 60_000)

    token =
      if minutes > 0,
        do: "token good for #{div(minutes, 60)} h #{rem(minutes, 60)} min",
        else: "token refreshes on the next call"

    "#{who} · #{token}"
  end

  defp signed_in?(status), do: Enum.any?(status, fn {_provider, st} -> st.signed_in end)

  defp boot_line do
    t = Operator.Boot.timings()

    "boot: dyn #{t[:dyn]} ms, apps #{t[:apps]} ms, total BEAM uptime #{t[:beam_uptime_at_boot_end]} ms"
  end
end
