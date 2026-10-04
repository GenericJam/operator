defmodule Operator.LoginScanScreen do
  @moduledoc """
  Diagnostics → Scan QR: reads the `operator://` QR codes made on the Mac
  (`Operator.Links`), camera permission first.

    * A login from `mix operator.login anthropic|openai`: takes the six
      words shown next to it, opens the code with `Operator.Auth.Transfer`
      and stores the login with `Operator.Auth.put/2`. The chat opens this
      screen at the words, with `%{link: link}`, for a login link scanned
      with another app.
    * A handoff part from `mix operator.handoff`: counted, then on to the
      next; the last one opens the chat on the new session.
    * The update server from `mix operator.deliver.qr`, checked by
      `Operator.Deliver.parse/1`: shown with the server in use, and saved
      (`Operator.Deliver.save/2`) only when "Use this server" is tapped. The
      chat opens this screen at that question, with `%{deliver: endpoint}`,
      for a link scanned with another app, so no link changes the server
      on its own.
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.Auth.Transfer
  alias Operator.Deliver
  alias Operator.Links
  alias Operator.LoginScanScreen.Native
  alias Operator.Toggle

  def mount(params, _session, socket) do
    socket =
      Mob.Socket.assign(socket,
        phase: :scan,
        qr: nil,
        words: "",
        deliver: nil,
        data_dir: Map.get(params, :data_dir) || Operator.Paths.data_dir(),
        line:
          "On the Mac, in the operator checkout: mix operator.login anthropic (or openai) " <>
            "to sign in, mix operator.handoff to carry on from omp, " <>
            "mix operator.deliver.qr for code updates."
      )

    case params do
      %{link: link} when is_binary(link) -> {:ok, words_step(socket, link)}
      %{deliver: endpoint} when is_binary(endpoint) -> {:ok, confirm_step(socket, endpoint)}
      _ -> {:ok, socket}
    end
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        {Toggle.title("Scan a code from your Mac")}
        <Spacer size={8} />
        <Text text={assigns.line} text_color={:primary} />
        <Spacer size={16} />
        {body(assigns)}
        <Spacer size={8} />
        {button("Back", :back)}
      </Column>
    </Scroll>
    """
  end

  def handle_info({:tap, :scan}, socket) do
    case Native.impl().request_camera() do
      :ok -> {:noreply, line(socket, "Allow the camera to scan the code.")}
      {:error, _} -> {:noreply, line(socket, "The camera isn't available on this device.")}
    end
  end

  def handle_info({:permission, :camera, :granted}, socket) do
    case Native.impl().scan() do
      :ok -> {:noreply, line(socket, "Point the camera at the QR on the Mac.")}
      {:error, _} -> {:noreply, line(socket, "The scanner couldn't open.")}
    end
  end

  def handle_info({:permission, :camera, _denied}, socket),
    do: {:noreply, line(socket, "No camera access: allow it in Settings, then scan again.")}

  def handle_info({:scan, :result, %{value: text}}, socket) when is_binary(text),
    do: {:noreply, scanned(socket, text)}

  # Scanned with another app while this screen shows.
  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, scanned(socket, link)}

  def handle_info({:scan, :cancelled}, socket),
    do: {:noreply, line(socket, "Scan cancelled.")}

  def handle_info({:scan, :permission_denied}, socket),
    do: {:noreply, line(socket, "No camera access: allow it in Settings, then scan again.")}

  def handle_info({:scan, _other}, socket),
    do: {:noreply, line(socket, "The scanner couldn't open.")}

  def handle_info({:change, :words, value}, socket) when is_binary(value),
    do: {:noreply, Mob.Socket.assign(socket, :words, value)}

  def handle_info({:tap, :submit}, %{assigns: %{qr: qr, words: words}} = socket)
      when is_binary(qr) do
    case Transfer.open(qr, words) do
      {:ok, provider, creds} ->
        {:noreply, store(socket, provider, creds)}

      {:error, :expired} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(phase: :scan, qr: nil, words: "")
         |> line(Transfer.message(:expired))}

      {:error, reason} ->
        {:noreply, line(socket, Transfer.message(reason))}
    end
  end

  # The tap carries the address its button showed: a link that replaced it
  # meanwhile is never the one saved.
  def handle_info({:tap, {:use_server, endpoint}}, %{assigns: %{deliver: endpoint}} = socket)
      when is_binary(endpoint) do
    text = Deliver.save(endpoint, socket.assigns.data_dir)
    {:noreply, socket |> Mob.Socket.assign(phase: :done, deliver: nil) |> line(text)}
  end

  def handle_info({:tap, :keep_server}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(phase: :scan, deliver: nil)
     |> line("Update server not changed.")}
  end

  def handle_info({:tap, :rescan}, socket),
    do: handle_info({:tap, :scan}, Mob.Socket.assign(socket, phase: :scan, qr: nil, words: ""))

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── helpers ──

  defp scanned(socket, text) do
    case Links.handle(text) do
      {:login, link} ->
        words_step(socket, link)

      {:handoff_part, received, total} ->
        socket
        |> Mob.Socket.assign(phase: :scan, qr: nil, words: "")
        |> line("Handoff #{received} of #{total} received: scan the rest.")

      # The handoff's session is current now: a fresh chat shows it.
      {:handoff, _handoff, _loop} ->
        Mob.Socket.reset_to(socket, Operator.ChatScreen)

      {:deliver, endpoint} ->
        confirm_step(socket, endpoint)

      {:error, text} ->
        line(socket, text)
    end
  end

  defp words_step(socket, link) do
    socket
    |> Mob.Socket.assign(phase: :words, qr: link, words: "")
    |> line("Code scanned. Type the six words shown on the Mac.")
  end

  defp confirm_step(socket, endpoint) do
    now =
      case Deliver.endpoint() do
        nil -> "none is set"
        current -> "now #{current}"
      end

    socket
    |> Mob.Socket.assign(phase: :confirm_deliver, deliver: endpoint, qr: nil, words: "")
    |> line("Get Operator's code updates from #{endpoint}? (#{now})")
  end

  defp body(%{phase: :scan}), do: button("Scan QR", :scan)

  defp body(%{phase: :words, words: words}) do
    %{
      type: :column,
      props: %{fill_width: true},
      children: [
        words_field(words),
        spacer(8),
        button("Sign in", :submit),
        spacer(8),
        button("Scan again", :rescan)
      ]
    }
  end

  defp body(%{phase: :confirm_deliver, deliver: endpoint}) do
    %{
      type: :column,
      props: %{fill_width: true},
      children: [
        button("Use this server", {:use_server, endpoint}),
        spacer(8),
        button("Cancel", :keep_server)
      ]
    }
  end

  defp body(%{phase: :done}), do: button("Scan another code", :rescan)

  defp line(socket, text), do: Mob.Socket.assign(socket, :line, text)

  defp store(socket, provider, creds) do
    case Auth.put(provider, creds) do
      :ok ->
        socket
        |> Mob.Socket.assign(phase: :done, qr: nil, words: "")
        |> line("Signed in to #{Auth.label(provider)}#{as(creds)}.")

      {:error, _reason} ->
        line(socket, "Couldn't save the login on this phone. Try again.")
    end
  end

  defp as(%{"email" => email}) when is_binary(email) and email != "", do: " as #{email}"
  defp as(_creds), do: ""

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

  defp spacer(size), do: ~MOB(<Spacer size={size} />)

  defp words_field(draft) do
    %{
      type: :text_field,
      props: %{
        value: draft,
        placeholder: "the six words, separated by spaces",
        fill_width: true,
        on_change: {self(), :words}
      },
      children: []
    }
  end
end
