defmodule Operator.HomeScreen do
  @moduledoc """
  Diagnostics (and the sign-in screen when there is no key yet): OpenRouter
  sign-in (localhost callback or pasted code), the agent stack's status, and
  the spike's on-device compilation of sample screens. Signing in hands over
  to `Operator.ChatScreen`.
  """
  use Mob.Screen

  alias Operator.OpenRouter.OAuth
  alias Operator.SelfMod

  def mount(_params, _session, socket) do
    # The theme (terminal font token included) is installed once at boot by
    # Operator.Core.Term.install/0.
    OAuth.subscribe()

    {:ok,
     Mob.Socket.assign(socket,
       oauth: OAuth.status(),
       code_draft: "",
       last: boot_line(),
       dyn: dyn_screens()
     )}
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
        <Text text="On-device compilation" text_size={:sm} text_color={:muted} />
        <Text text={assigns.last} text_color={:primary} />
        <Spacer size={8} />
        {button("Compile + install Hello", {:compile, "hello"})}
        <Spacer size={8} />
        {button("Compile + install Checklist (~200 lines)", {:compile, "checklist"})}
        <Spacer size={8} />
        {button("Forget compiled screens", :forget)}
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

  # ── self-modification ──

  def handle_info({:tap, {:compile, name}}, socket) do
    line =
      case SelfMod.install(name, SelfMod.Samples.get(name)) do
        {:ok, r} ->
          "#{name}: #{inspect(r.modules)} compiled in #{div(r.compile_us, 1000)} ms, selftest #{inspect(r.selftest)}"

        {:error, e} ->
          "#{name} failed: #{inspect(e) |> String.slice(0, 300)}"
      end

    {:noreply, Mob.Socket.assign(socket, last: line, dyn: dyn_screens())}
  end

  def handle_info({:tap, :forget}, socket) do
    Enum.each(SelfMod.list(), &SelfMod.remove/1)

    {:noreply,
     Mob.Socket.assign(socket,
       last: "persisted sources removed (modules stay loaded until restart)"
     )}
  end

  def handle_info({:tap, {:open, mod}}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, mod)}

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

  defp dyn_section([]), do: ~MOB(<Text text="No compiled screens yet" text_color={:muted} />)

  defp dyn_section(mods) do
    buttons = Enum.map(mods, fn m -> button("Open " <> inspect(m), {:open, m}) end)
    %{type: :column, props: %{fill_width: true}, children: buttons}
  end

  defp dyn_screens, do: SelfMod.screens() |> Enum.sort()

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

    "boot: selfmod recompile #{t[:selfmod_recompile]} ms, apps #{t[:apps]} ms, total BEAM uptime #{t[:beam_uptime_at_boot_end]} ms"
  end
end
