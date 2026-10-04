defmodule Operator.RescueScreen do
  @moduledoc """
  The rescue screen (docs/DESIGN.md §2, safe mode): every Dyn generation
  (number, status, when, rationale), a generation's diff, reverting to any
  generation that was active once (approved like an activation: "Revert to
  this", then the approve chip, `Operator.Core.ApproveButton`, whose pass
  goes through `Operator.Core.Dyn.request_approval/2`), and the crash log.

  The app opens it instead of the chat in safe mode; the diagnostics screen
  links to it. It is Core code: nothing the agent writes can remove or
  cover it.
  """
  use Mob.Screen

  alias Operator.ChatScreen.Native
  alias Operator.Core.ApproveButton
  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Generation
  alias Operator.Core.Term
  alias Operator.Toggle

  @log_limit 30

  def mount(_params, _session, socket) do
    Dyn.subscribe()

    {:ok,
     socket
     |> Mob.Socket.assign(selected: nil, diff: "", message: nil, reverting: nil)
     |> load()}
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        {Toggle.title("Rescue")}
        <Text text={status_line(assigns.status)} text_color={:primary} />
        {message(assigns.message)}
        <Spacer size={8} />
        {button("Back", :back, :surface)}
        <Spacer size={8} />
        {button("Open the chat", :chat, :surface)}
        <Spacer size={16} />
        <Text text="Generations" text_size={:sm} text_color={:muted} />
        {generations(assigns)}
        <Spacer size={16} />
        <Text text="Crash log" text_size={:sm} text_color={:muted} />
        {log(assigns.log)}
      </Column>
    </Scroll>
    """
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

  def handle_info({:tap, :chat}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.ChatScreen)}

  def handle_info({:tap, {:diff, n}}, socket) do
    if socket.assigns.selected == n,
      do: {:noreply, Mob.Socket.assign(socket, selected: nil, diff: "")},
      else: {:noreply, Mob.Socket.assign(socket, selected: n, diff: Dyn.diff(n))}
  end

  def handle_info({:tap, {:revert, n}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, reverting: n, message: nil)}

  def handle_info({:tap, :cancel_revert}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :reverting, nil)}

  # Off Android there's no screen-lock prompt: the plain button asks for a
  # token unconfirmed, which only an approval needing no confirmation grants.
  def handle_info({:tap, :approve_revert}, %{assigns: %{reverting: n}} = socket)
      when is_integer(n),
      do: {:noreply, revert(socket, n)}

  def handle_info({:approval, "approved", %{"subject" => {:revert_to, n} = subject}}, socket) do
    case Native.impl().confirm_approval(subject) do
      :ok -> {:noreply, revert(socket, n)}
      {:error, reason} -> {:noreply, Mob.Socket.assign(socket, :message, not_reverted(reason))}
    end
  end

  def handle_info({:approval, "failed", payload}, socket),
    do:
      {:noreply,
       Mob.Socket.assign(
         socket,
         :message,
         "Not reverted: " <> ApproveButton.why("failed", payload)
       )}

  def handle_info({:approval, "unavailable", payload}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :message, ApproveButton.why("unavailable", payload))}

  def handle_info({:operator_dyn, _event}, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp revert(socket, n) do
    message =
      with {:ok, token} <- Dyn.request_approval({:revert_to, n}),
           {:ok, _gen} <- Dyn.revert_to(n, token) do
        if Dyn.safe_mode?(),
          do: "Generation #{n} is current; it loads on the next launch.",
          else: "Generation #{n} is current."
      else
        {:error, :approval_required} ->
          "Not reverted: it needs approving through the phone's screen-lock prompt."

        {:error, reason} ->
          not_reverted(reason)
      end

    socket |> Mob.Socket.assign(message: message, reverting: nil) |> load()
  end

  defp not_reverted(reason), do: "Not reverted: #{inspect(reason) |> String.slice(0, 300)}"

  # ── view ──

  defp load(socket) do
    Mob.Socket.assign(socket,
      status: Dyn.status(),
      gens: Dyn.generations(),
      log: Enum.reverse(Dyn.log(@log_limit))
    )
  end

  defp status_line(%{mode: :safe, generation: n}),
    do: "Safe mode: the last launches never got going, so no Dyn code is loaded. Current: G#{n}."

  defp status_line(%{mode: :off}), do: "The Dyn keeper isn't running."
  defp status_line(%{generation: n, status: status}), do: "Running G#{n} (#{status})."

  defp message(nil), do: spacer(0)
  defp message(text), do: text(text, :on_surface, :base)

  defp generations(assigns) do
    rows = Enum.map(assigns.gens, &generation(&1, assigns))
    column(rows)
  end

  defp generation(%Generation{} = gen, assigns) do
    current? = gen.n == assigns.status.generation
    head = "G#{gen.n} · #{gen.status}" <> if(current?, do: " · current", else: "") <> created(gen)

    diff_action =
      if gen.n > 0,
        do: [
          button(
            if(assigns.selected == gen.n, do: "Hide diff", else: "Diff"),
            {:diff, gen.n},
            :surface
          )
        ],
        else: []

    diff =
      if assigns.selected == gen.n,
        do: [mono(if(assigns.diff == "", do: "(no changes)", else: assigns.diff))],
        else: []

    column(
      [text(head, :on_surface, :base), text(gen.rationale, :muted, :sm)] ++
        reason(gen) ++
        diff_action ++ revert_actions(gen, current?, assigns) ++ diff ++ [spacer(8)]
    )
  end

  defp revert_actions(gen, current?, assigns) do
    cond do
      not Generation.ever_active?(gen) or current? ->
        []

      assigns.reverting == gen.n ->
        [approve_revert(gen.n), button("Cancel", :cancel_revert, :surface)]

      true ->
        [button("Revert to this", {:revert, gen.n}, :primary)]
    end
  end

  # The system screen-lock prompt (a native view on the phone).
  defp approve_revert(n) do
    if Term.platform() in [:android, :ios] do
      palette = Mob.Theme.resolved_palette()

      Mob.UI.native_view(ApproveButton,
        id: :approve_revert,
        notify: self(),
        subject: {:revert_to, n},
        label: "Approve revert to G#{n}",
        title: "Revert to generation #{n}",
        subtitle: "Operator runs that generation's code again",
        text_color: palette[:on_primary],
        background: palette[:primary]
      )
    else
      button("Approve revert to G#{n}", :approve_revert, :primary)
    end
  end

  defp created(%Generation{created_at: nil}), do: ""
  defp created(%Generation{created_at: at}), do: " · " <> at

  defp reason(%Generation{reason: nil}), do: []
  defp reason(%Generation{reason: reason}), do: [text(String.slice(reason, 0, 400), :muted, :sm)]

  defp log([]), do: text("No crashes.", :muted, :sm)

  defp log(entries) do
    entries
    |> Enum.map(fn e ->
      parts = [e[:at], e[:gen] && "G#{e[:gen]}", e[:type], e[:module], e[:reason]]
      parts |> Enum.filter(& &1) |> Enum.join(" ") |> String.slice(0, 400) |> mono()
    end)
    |> column()
  end

  defp button(label, tag, background) do
    %{
      type: :button,
      props: %{
        text: label,
        background: background,
        text_color: if(background == :primary, do: :on_primary, else: :on_surface),
        padding: :space_sm,
        fill_width: true,
        on_tap: {self(), tag}
      },
      children: []
    }
  end

  defp text(text, color, size),
    do: %{type: :text, props: %{text: text, text_color: color, text_size: size}, children: []}

  defp mono(text) do
    %{
      type: :text,
      props: %{text: text, font: :term, text_color: :on_surface, text_size: :sm},
      children: []
    }
  end

  defp spacer(size), do: %{type: :spacer, props: %{size: size}, children: []}
  defp column(children), do: %{type: :column, props: %{fill_width: true}, children: children}
end
