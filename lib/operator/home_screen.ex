defmodule Operator.HomeScreen do
  @moduledoc """
  Diagnostics (and the sign-in screen when there is no key yet): OpenRouter
  sign-in (localhost callback or pasted code), the agent stack's status,
  and the Dyn layer: its current generation, sample proposals that run the
  self-modification pipeline on the phone, its screens, and the way to the
  rescue screen. Signing in hands over to `Operator.ChatScreen`.
  """
  use Mob.Screen

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Samples
  alias Operator.OpenRouter.OAuth

  def mount(_params, _session, socket) do
    # The theme (terminal font token included) is installed once at boot by
    # Operator.Core.Term.install/0.
    OAuth.subscribe()
    Dyn.subscribe()

    {:ok,
     socket
     |> Mob.Socket.assign(oauth: OAuth.status(), code_draft: "", last: boot_line())
     |> dyn()}
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Operator" text_size={:xl} text_color={:on_surface} />
        <Text text={stack_line()} text_size={:sm} text_color={:muted} />
        <Spacer size={16} />
        <Text text="OpenRouter" text_size={:sm} text_color={:muted} />
        <Text text={oauth_line(assigns.oauth)} text_color={:primary} />
        <Spacer size={8} />
        {button("Sign in with OpenRouter", :sign_in_localhost)}
        <Spacer size={8} />
        {button("Sign in (show code to paste)", :sign_in_headless)}
        <Spacer size={8} />
        {code_field(assigns.code_draft)}
        <Spacer size={8} />
        {button("Submit pasted code", :submit_code)}
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

  def handle_info({:tap, :sign_in_localhost}, socket), do: begin(socket, :localhost)
  def handle_info({:tap, :sign_in_headless}, socket), do: begin(socket, :headless)

  def handle_info({:change, :code, value}, socket) when is_binary(value),
    do: {:noreply, Mob.Socket.assign(socket, :code_draft, value)}

  def handle_info({:tap, :submit_code}, socket) do
    _ = OAuth.exchange_pasted(socket.assigns.code_draft)

    {:noreply, Mob.Socket.assign(socket, code_draft: "", oauth: OAuth.status())}
  end

  def handle_info({:oauth, _phase}, socket) do
    status = OAuth.status()
    socket = Mob.Socket.assign(socket, :oauth, status)

    if status.phase == :signed_in and status.key_present,
      do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen)},
      else: {:noreply, socket}
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
              "G#{n} waits for approval (the biometric prompt isn't wired yet)"

            {:error, e} ->
              "G#{n} not activated: #{inspect(e) |> String.slice(0, 300)}"
          end
      end

    {:noreply, socket |> Mob.Socket.assign(:last, line) |> dyn()}
  end

  def handle_info({:tap, :rescue}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.RescueScreen)}

  def handle_info({:tap, {:open, mod}}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, mod)}

  def handle_info({:operator_dyn, _event}, socket), do: {:noreply, dyn(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── helpers ──

  defp begin(socket, mode) do
    _ = OAuth.begin(mode)
    {:noreply, Mob.Socket.assign(socket, :oauth, OAuth.status())}
  end

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

  defp code_field(draft) do
    %{
      type: :text_field,
      props: %{
        value: draft,
        placeholder: "paste the OpenRouter code",
        fill_width: true,
        on_change: {self(), :code}
      },
      children: []
    }
  end

  defp dyn_section([]), do: ~MOB(<Text text="No Dyn screens" text_color={:muted} />)

  defp dyn_section(screens) do
    buttons = Enum.map(screens, fn {name, mod} -> button("Open " <> name, {:open, mod}) end)
    %{type: :column, props: %{fill_width: true}, children: buttons}
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

  defp oauth_line(%{phase: phase, error: nil, key_fingerprint: fp}),
    do: "#{phase}" <> if(fp, do: " · key #{fp}…", else: "")

  defp oauth_line(%{phase: phase, error: err}),
    do: "#{phase}: #{inspect(err) |> String.slice(0, 200)}"

  defp boot_line do
    t = Operator.Boot.timings()

    "boot: dyn #{t[:dyn]} ms, apps #{t[:apps]} ms, total BEAM uptime #{t[:beam_uptime_at_boot_end]} ms"
  end
end
