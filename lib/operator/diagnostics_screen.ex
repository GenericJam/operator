defmodule Operator.DiagnosticsScreen do
  @moduledoc """
  Menu › diagnostics (`Operator.MenuScreen`), drawn like the terminal
  (`Operator.TermUI`): the agent stack's status, today's model spend against
  the daily cost cap (editable), code updates from the Mac
  (`Operator.Deliver`: the update server, the code running, the last check,
  "check for updates now"; a QR scan sets the server), and the Dyn layer:
  its current generation, sample proposals that run the self-modification
  pipeline on the phone, the way to the rescue screen, and its front
  screens. An `operator://` link scanned with another app while this
  screen shows goes to the chat.
  """
  use Mob.Screen

  alias Operator.Core.Budget
  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Samples
  alias Operator.Core.Front
  alias Operator.Core.Settings
  alias Operator.Core.Term
  alias Operator.Deliver
  alias Operator.TermUI, as: UI
  alias Operator.Toggle

  def mount(params, _session, socket) do
    Dyn.subscribe()
    data_dir = Map.get(params, :data_dir) || Operator.Paths.data_dir()

    {:ok,
     socket
     |> Mob.Socket.assign(last: boot_line())
     |> Mob.Socket.assign(data_dir: data_dir, cap_draft: "", updates: nil, update_note: nil)
     |> spend()
     |> dyn()
     |> refresh_updates()}
  end

  def render(assigns) do
    t = Term.theme()

    rows =
      [
        UI.heading("agent stack", t),
        UI.line(stack_line(), t),
        UI.heading("spending", t),
        UI.line(assigns.spend_line, t),
        UI.actions(t, [
          UI.field(assigns.cap_draft, "daily cap in $, e.g. 2.50", :cap, t, weight: 1),
          UI.chip("save cap", :save_cap, t)
        ]),
        UI.heading("code updates from the Mac", t)
      ] ++
        updates_section(assigns, t) ++
        [
          UI.actions(t, [
            UI.link("check for updates now", :check_updates, t),
            UI.link("scan QR", :scan_qr, t)
          ]),
          UI.heading("dyn layer (self-modification)", t),
          UI.line(assigns.dyn_line, t),
          UI.line(assigns.last, t, "dim"),
          UI.item("propose sample: hello", "", {:propose, "hello"}, t),
          UI.item("propose sample: checklist", "~200 lines", {:propose, "checklist"}, t),
          UI.item("activate the proposal", "", :activate, t),
          UI.item("rescue", "generations, diffs, crash log", :rescue, t),
          UI.heading("front screens", t)
        ] ++ dyn_section(assigns.dyn, t)

    UI.page(t, "menu › diagnostics", rows)
  end

  # ── navigation ──

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :scan_qr}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.LoginScanScreen)}

  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen, %{link: link})}

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

  defp refresh_updates(socket) do
    screen = self()
    {:ok, _} = Task.start(fn -> send(screen, {:operator_deliver, :status, Deliver.status()}) end)
    socket
  end

  defp updates_section(%{updates: nil}, t), do: [UI.line("…", t, "dim")]

  defp updates_section(%{updates: status, update_note: note}, t) do
    lines = for line <- Deliver.status_lines(status) ++ List.wrap(note), do: UI.line(line, t)

    dismiss =
      if status.rollback,
        do: [UI.actions(t, [UI.link("dismiss the rollback notice", :dismiss_rollback, t)])],
        else: []

    lines ++ dismiss
  end

  defp spend(socket) do
    dir = socket.assigns.data_dir
    spent = :erlang.float_to_binary(Budget.spent(dir), decimals: 4)
    cap = :erlang.float_to_binary(Settings.daily_cap(dir), decimals: 2)
    Mob.Socket.assign(socket, :spend_line, "Today $#{spent} of the $#{cap} daily cap")
  end

  defp dyn_section([], t), do: [UI.line("no front screens", t, "dim")]

  # One tappable line per front screen (the default front alone has 67).
  defp dyn_section(screens, t),
    do: for({name, _mod} <- screens, do: UI.item(name, "", {:open, name}, t))

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
    if down == [], do: "all apps running", else: "DOWN: #{inspect(down)}"
  end

  defp boot_line do
    t = Operator.Boot.timings()

    "boot: dyn #{t[:dyn]} ms, apps #{t[:apps]} ms, total BEAM uptime #{t[:beam_uptime_at_boot_end]} ms"
  end
end
