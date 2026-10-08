defmodule Operator.ShellScreen do
  @moduledoc """
  The front, on screen (PLAN.md "Front and back"): the open front screen
  full-bleed, and over it the toggle in the upper left corner, the only
  thing Operator draws there. The toggle (or Android's back) goes back to
  the terminal, which this screen was pushed over (`Operator.Toggle`).

  It never runs front code: the front screen runs in its own process
  (`Operator.Core.Front.Host`), and this screen draws the view that
  process renders, which `Operator.Core.Front` sends it as data. Taps on
  the front go straight to that process; anything else this screen gets
  (a `Mob.Test.tap/2`, say) is passed on to it. A front screen that
  crashed shows its error here instead; showing the front again retries
  it.
  """
  use Mob.Screen

  alias Operator.Core.Front
  alias Operator.Core.Phone
  alias Operator.Toggle

  @zero %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0}

  # Subscribed before `show/1`: the first view usually arrives after it (the
  # host renders once started), and so do crashes, new generations and the
  # front's requests for the terminal.
  def mount(_params, _session, socket) do
    _ = Front.subscribe()
    front = Front.show(env(socket)) |> Map.put_new(:capability_key, nil)
    {:ok, Mob.Socket.assign(socket, :front, front)}
  end

  def render(assigns) do
    %{
      type: :box,
      props: %{fill_width: true, fill_height: true, background: :background},
      children: [front(assigns.front.view), Toggle.overlay()]
    }
  end

  def handle_info({:operator_front, snapshot}, socket) do
    old = socket.assigns.front

    key =
      if old.host == snapshot.host,
        do: old.capability_key,
        else: Map.get(snapshot, :capability_key)

    {:noreply, Mob.Socket.assign(socket, :front, Map.put(snapshot, :capability_key, key))}
  end

  def handle_info({:operator_front_capability, host, key}, socket)
      when is_pid(host) and is_reference(key) do
    if socket.assigns.front.host == host do
      {:noreply, Mob.Socket.assign(socket, :front, %{socket.assigns.front | capability_key: key})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:tap, :operator_toggle}, socket) do
    :ok = Front.hide()
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  # The front screen asked for the terminal (Operator.Core.Terminal), with a
  # draft for the composer: the chat (Phone's host) gets it, unsent.
  def handle_info({:operator_front_terminal, draft}, socket) do
    :ok = Front.hide()
    chat = Phone.host()
    if chat && draft != "", do: send(chat, {:operator_draft, draft})
    {:noreply, Mob.Socket.pop_to(socket, Operator.ChatScreen)}
  end

  # An operator:// link scanned while the front shows: the chat handles it.
  def handle_info({:link, %{url: url}}, socket) when is_binary(url) do
    :ok = Front.hide()
    {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen, %{link: url})}
  end

  # Native capability replies arrive at :mob_screen. The unguessable key was
  # handed directly from Core to this shell, never to front code.
  def handle_info(message, socket) do
    with %{host: host, capability_key: key} when is_pid(host) and is_reference(key) <-
           socket.assigns.front,
         do: send(host, {Operator.Core.Front.Host, :native, key, message})

    {:noreply, socket}
  end

  # However the front was left (the toggle, Android's back, the front asking
  # for the terminal), the terminal is on screen again.
  def terminate(_reason, _socket) do
    if chat = Phone.host(), do: send(chat, :operator_terminal_shown)
    :ok
  end

  defp front({:tree, tree}), do: layer([tree])

  defp front({:error, text}) do
    layer([
      %{
        type: :scroll,
        props: %{fill_width: true, fill_height: true, background: :background},
        children: [
          %{
            type: :column,
            props: %{fill_width: true, padding: 16},
            children: [
              %{type: :spacer, props: %{size: 52}, children: []},
              text("This front screen crashed.", :on_surface, :lg),
              text(
                "Switch to the terminal and back to try it again, or ask the agent to fix it.",
                :muted,
                :sm
              ),
              %{type: :spacer, props: %{size: 12}, children: []},
              text(text, :on_surface, :sm)
            ]
          }
        ]
      }
    ])
  end

  defp front({:note, note}) do
    layer([
      %{
        type: :column,
        props: %{fill_width: true, fill_height: true, padding: 16},
        children: [%{type: :spacer, props: %{size: 52}, children: []}, text(note, :muted, :base)]
      }
    ])
  end

  defp layer(children),
    do: %{type: :box, props: %{fill_width: true, fill_height: true}, children: children}

  defp text(text, color, size) do
    %{type: :text, props: %{text: text, text_color: color, text_size: size}, children: []}
  end

  defp env(socket) do
    %{
      platform: socket.__mob__.platform,
      safe_area: socket.assigns[:safe_area] || @zero,
      size_class: socket.assigns[:size_class] || Mob.SizeClass.placeholder()
    }
  end
end
