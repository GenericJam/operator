defmodule Operator.ClusterScreen do
  @moduledoc """
  The human-facing control for Operator's local TLS cluster.

  Clustering is off until the user enables it. Pairing is an explicit,
  short-lived flow: one phone shows a QR, the other scans it, reviews the
  node and certificate fingerprint, then confirms with the system screen
  lock. Leaving this screen closes any pairing window and removes its QR.
  """
  use Mob.Screen

  alias Operator.Cluster
  alias Operator.Cluster.Invite
  alias Operator.Core.ApproveButton
  alias Operator.Core.Term
  alias Operator.LoginScanScreen.Native
  alias Operator.TermUI, as: UI
  alias Operator.Toggle

  @qr_file "cluster/invite.png"

  @impl true
  def mount(params, _session, socket) do
    :ok = Cluster.subscribe()

    socket =
      Mob.Socket.assign(socket,
        status: Cluster.status(),
        invite: nil,
        qr_path: nil,
        candidate: nil,
        candidate_id: 0,
        note: nil
      )

    case params do
      %{invite: invite} when is_map(invite) -> {:ok, candidate(socket, invite)}
      %{link: link} when is_binary(link) -> {:ok, scanned(socket, link)}
      _ -> {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    t = Term.theme()

    rows =
      [
        UI.heading("local TLS cluster", t),
        UI.line(status_line(assigns.status), t),
        UI.line(node_line(assigns.status), t, "dim"),
        UI.actions(t, status_actions(assigns.status, t))
      ] ++
        restart_rows(assigns.status, t) ++
        pairing_rows(assigns, t) ++
        candidate_rows(assigns, t) ++
        peer_rows(assigns.status.peers, t) ++
        note_rows(assigns.note, t)

    UI.page(t, "menu › cluster", rows)
  end

  @impl true
  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :operator_toggle}, socket),
    do: {:noreply, Toggle.to_front(socket)}

  def handle_info({:tap, :enable}, socket) do
    note =
      case Cluster.enable() do
        :ok -> "Cluster enabled."
        {:error, :restart_needed} -> "Cluster enabled. Close and reopen Operator once."
        {:error, reason} -> "Couldn't start the cluster: #{inspect(reason)}"
      end

    {:noreply, refresh(socket, note)}
  end

  def handle_info({:tap, :disable}, socket) do
    :ok = Cluster.disable()
    {:noreply, socket |> clear_pairing() |> refresh("Cluster disabled.")}
  end

  def handle_info({:tap, :invite}, socket) do
    case Cluster.invite() do
      {:ok, link} ->
        {:noreply, show_invite(socket, link)}

      {:error, :not_running} ->
        {:noreply, refresh(socket, "Start the cluster before inviting a peer.")}
    end
  end

  def handle_info({:tap, :close_pairing}, socket),
    do: {:noreply, socket |> clear_pairing() |> refresh("Pairing closed.")}

  def handle_info({:tap, :scan}, socket) do
    case Native.impl().request_camera() do
      :ok -> {:noreply, note(socket, "Allow the camera to scan the other Operator's QR.")}
      {:error, _} -> {:noreply, note(socket, "The camera isn't available on this device.")}
    end
  end

  def handle_info({:permission, :camera, :granted}, socket) do
    case Native.impl().scan() do
      :ok -> {:noreply, note(socket, "Point the camera at the other Operator's QR.")}
      {:error, _} -> {:noreply, note(socket, "The scanner couldn't open.")}
    end
  end

  def handle_info({:permission, :camera, _denied}, socket),
    do: {:noreply, note(socket, "No camera access: allow it in Settings, then scan again.")}

  def handle_info({:scan, :result, %{value: text}}, socket) when is_binary(text),
    do: {:noreply, scanned(socket, text)}

  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, scanned(socket, link)}

  def handle_info({:scan, :cancelled}, socket), do: {:noreply, note(socket, "Scan cancelled.")}

  def handle_info({:scan, _other}, socket),
    do: {:noreply, note(socket, "The scanner couldn't read that code.")}

  def handle_info({:tap, :cancel_join}, socket),
    do: {:noreply, Mob.Socket.assign(socket, candidate: nil, note: "Invite not used.")}

  def handle_info(
        {:approval, "approved", %{"subject" => {:cluster_join, id}}},
        %{assigns: %{candidate_id: id, candidate: invite}} = socket
      )
      when is_map(invite) do
    case Cluster.join(invite) do
      :ok ->
        {:noreply,
         socket
         |> Mob.Socket.assign(candidate: nil)
         |> refresh("Invite accepted. Connecting to #{invite.node}…")}

      {:error, :restart_needed} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(candidate: nil)
         |> refresh("Invite accepted. Close and reopen Operator once to connect.")}

      {:error, reason} ->
        {:noreply, refresh(socket, "Couldn't join: #{inspect(reason)}")}
    end
  end

  def handle_info({:approval, "failed", payload}, socket),
    do: {:noreply, note(socket, "Not joined: " <> ApproveButton.why("failed", payload))}

  def handle_info({:approval, "unavailable", payload}, socket),
    do: {:noreply, note(socket, ApproveButton.why("unavailable", payload))}

  def handle_info({:approval, _event, _payload}, socket), do: {:noreply, socket}

  # Host-only fallback for the native approval view.
  def handle_info({:tap, :approve_join}, %{assigns: %{candidate_id: id}} = socket),
    do: handle_info({:approval, "approved", %{"subject" => {:cluster_join, id}}}, socket)

  def handle_info({:tap, {:forget, fingerprint}}, socket) do
    :ok = Cluster.forget(fingerprint)
    {:noreply, refresh(socket, "Peer forgotten and revoked.")}
  end

  def handle_info({:operator_cluster, :changed}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _ = clear_pairing(socket)
    :ok
  end

  defp scanned(socket, text) do
    case Invite.parse(text) do
      {:ok, invite} -> candidate(socket, invite)
      {:error, message} -> note(socket, message)
      :not_cluster -> note(socket, "That QR isn't an Operator cluster invite.")
    end
  end

  defp candidate(socket, invite) do
    id = socket.assigns.candidate_id + 1

    socket
    |> Mob.Socket.assign(candidate: invite, candidate_id: id)
    |> note("Review this peer, then unlock the phone to join it.")
  end

  defp show_invite(socket, link) do
    path = Path.join(Operator.Paths.data_dir(), @qr_file)
    :ok = File.mkdir_p(Path.dirname(path))
    png = link |> EQRCode.encode(:m) |> EQRCode.png()
    :ok = File.write(path, png, [:binary])
    :ok = File.chmod(path, 0o600)

    socket
    |> Mob.Socket.assign(invite: link, qr_path: path, candidate: nil)
    |> refresh("Pairing is open for five minutes. Keep this QR private.")
  rescue
    error ->
      # Nobody can see the invite: don't leave its window open.
      :ok = Cluster.close_pairing()
      refresh(socket, "Couldn't draw the invite QR: #{Exception.message(error)}")
  end

  defp clear_pairing(socket) do
    if socket.assigns.invite do
      :ok = Cluster.close_pairing()
      if socket.assigns.qr_path, do: File.rm(socket.assigns.qr_path)
    end

    Mob.Socket.assign(socket, invite: nil, qr_path: nil)
  end

  defp refresh(socket, note \\ nil) do
    socket
    |> Mob.Socket.assign(:status, Cluster.status())
    |> then(fn socket -> if note, do: Mob.Socket.assign(socket, :note, note), else: socket end)
  end

  defp note(socket, text), do: Mob.Socket.assign(socket, :note, text)

  defp status_line(%{enabled: false}), do: "off · no LAN listener"
  defp status_line(%{running: true}), do: "on · TLS 1.3 · port #{Cluster.port()}"
  defp status_line(%{enabled: true}), do: "on · waiting for restart"

  defp node_line(%{node: nil}), do: "No cluster node is running."
  defp node_line(%{node: node}), do: Atom.to_string(node)

  defp status_actions(%{enabled: false}, t),
    do: [UI.link("enable", :enable, t), UI.link("scan invite", :scan, t)]

  defp status_actions(%{running: true}, t),
    do: [
      UI.link("show invite", :invite, t),
      UI.link("scan invite", :scan, t),
      UI.link("disable", :disable, t)
    ]

  defp status_actions(_status, t),
    do: [UI.link("scan invite", :scan, t), UI.link("disable", :disable, t)]

  defp restart_rows(%{enabled: true, running: false, restart_needed: true}, t),
    do: [UI.line("Close and reopen Operator once to start encrypted distribution.", t, "notice")]

  defp restart_rows(_status, _t), do: []

  defp pairing_rows(%{invite: invite, qr_path: path}, t) when is_binary(invite) do
    [
      UI.heading("invite", t),
      %{
        type: :image,
        props: %{src: path, width: 260, height: 260, content_mode: :fit},
        children: []
      },
      UI.line("Scan on the other phone. The code contains the cluster secret.", t, "notice"),
      UI.actions(t, [UI.link("close pairing", :close_pairing, t)])
    ]
  end

  defp pairing_rows(_assigns, _t), do: []

  defp candidate_rows(%{candidate: nil}, _t), do: []

  defp candidate_rows(%{candidate: invite, candidate_id: id}, t) do
    [
      UI.heading("join this peer?", t),
      UI.line(invite.node, t),
      UI.line("certificate " <> short(invite.fingerprint), t, "dim"),
      UI.bar_row(t, [
        UI.chip("cancel", :cancel_join, t, "error"),
        approve_chip(id, invite.node, t)
      ])
    ]
  end

  defp peer_rows([], t), do: [UI.heading("peers", t), UI.line("none", t, "dim")]

  defp peer_rows(peers, t) do
    [UI.heading("peers", t)] ++
      Enum.flat_map(peers, fn peer ->
        state = if peer.connected, do: "connected", else: "offline"

        [
          UI.item(peer.node, state, {:forget, peer.fingerprint}, t,
            color: if(peer.connected, do: "accent", else: "dim")
          ),
          UI.line("tap to forget · " <> short(peer.fingerprint), t, "dim",
            text_size: t.text_size - 1
          )
        ]
      end)
  end

  defp note_rows(nil, _t), do: []
  defp note_rows(text, t), do: [UI.line(text, t, "notice")]

  defp approve_chip(id, node, t) do
    if Term.platform() in [:android, :ios] do
      Mob.UI.native_view(ApproveButton,
        id: :approve_cluster_join,
        notify: self(),
        subject: {:cluster_join, id},
        label: "join",
        title: "Join Operator cluster",
        subtitle: node,
        text_color: Term.color(t, "user"),
        background: Term.color(t, "code_bg"),
        text_size: t.text_size - 1,
        font: Term.markdown_props(t).font_regular
      )
    else
      UI.chip("join", :approve_join, t, "user")
    end
  end

  defp short(fingerprint), do: String.slice(fingerprint, 0, 16) <> "…"
end
