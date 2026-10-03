defmodule Operator.ChatScreen do
  @moduledoc """
  The app's root after sign-in: a terminal onto the current session's
  `Operator.Core.Loop`.

  A transcript `:lazy_list` fills the screen (virtualized natively; one item
  per line, each a `:wrap` of styled text from `Operator.Core.Term`, or with
  the `:native` renderer one native Markdown view per prose stretch of a
  reply), a status line on top, the composer pinned at the bottom: Send
  while idle, Steer while the agent runs, plus Stop. Streamed deltas are
  buffered and painted at most every #{100} ms; completed messages keep
  their rows, only the streaming reply is re-rendered. Only the last
  `@window` rows (at most `@max_native` of them native views: each takes
  one of mob's 256 native component slots) are rendered ("show earlier"
  extends it). The list follows new output unless the user scrolled up
  (`Operator.ChatScreen.Follow`).

  Long-press a line to copy its whole message (native Markdown rows select
  text instead: long-press, drag the handles, Copy); `[copy]` on a code
  fence copies that block; "copy last reply" copies the last assistant
  message. The `md:` chip switches the renderer (`Term.put_renderer/1`).
  """
  use Mob.Screen

  alias Operator.ChatScreen.Follow
  alias Operator.ChatScreen.Native
  alias Operator.Core.Loop
  alias Operator.Core.Session
  alias Operator.Core.Term
  alias Operator.Core.Term.Markup
  alias Operator.Core.Term.Stream, as: TermStream

  @flush_ms 100
  @stick_ms 60
  @toast_ms 1_500
  @window 300
  @max_native 200
  @list_id "transcript"

  def mount(params, _session, socket) do
    loop = Map.get(params, :loop) || Operator.Core.current()

    {:ok,
     socket
     |> Mob.Socket.assign(window: @window, draft: "", model_draft: nil, toast: nil)
     |> attach(loop)}
  end

  def render(assigns) do
    t = Term.theme()
    bg = Term.color(t, "bg")

    %{
      type: :column,
      props: %{fill_width: true, fill_height: true, background: bg},
      children:
        [header(assigns, t)] ++
          model_editor(assigns, t) ++
          [
            %{
              type: :lazy_list,
              props: %{id: @list_id, weight: 1, padding: t.padding, background: bg},
              children: assigns.visible
            },
            footer(assigns, t),
            composer(assigns, t)
          ]
    }
  end

  # ── loop events ──

  def handle_info({:operator_core, sid, event}, %{assigns: %{sid: sid}} = socket),
    do: {:noreply, on_event(event, socket)}

  def handle_info({:operator_core, _other, _event}, socket), do: {:noreply, socket}

  def handle_info(:flush, socket) do
    socket = Mob.Socket.assign(socket, :flush_timer, nil)

    case socket.assigns.stream do
      nil ->
        {:noreply, socket}

      st ->
        delta = IO.iodata_to_binary(st.pending)
        st = %{st | acc: TermStream.feed(st.acc, delta), text: [st.text, delta], pending: []}
        {:noreply, socket |> Mob.Socket.assign(:stream, st) |> repaint()}
    end
  end

  def handle_info(:stick, socket) do
    native = Native.impl()

    with %{} = info <- native.scroll_info(@list_id) do
      {x, y} = Follow.bottom(info)
      native.scroll_to(@list_id, x, y)
    end

    {:noreply, socket}
  end

  def handle_info(:clear_toast, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:toast, nil) |> refresh()}

  # ── composer ──

  def handle_info({:change, :draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info({:submit, :draft}, socket), do: send_draft(socket)
  def handle_info({:tap, :send}, socket), do: send_draft(socket)

  def handle_info({:tap, :stop}, socket) do
    Loop.stop(socket.assigns.loop)
    {:noreply, socket}
  end

  # ── copy ──

  def handle_info({:long_press, {:copy, key}}, socket),
    do: {:noreply, copy(socket, message_text(socket, key, :plain))}

  def handle_info({:tap, {:copy_code, key, n}}, socket) do
    text = socket |> message_text(key, :raw) |> then(&(&1 && Markup.code_block(&1, n)))
    {:noreply, copy(socket, text)}
  end

  def handle_info({:tap, :copy_last}, socket) do
    entry =
      Enum.find_value(socket.assigns.done_rev, fn %{entry: e} ->
        if assistant_text?(e), do: e
      end)

    {:noreply, copy(socket, entry && Term.plain_text(entry))}
  end

  # ── header actions ──

  def handle_info({:tap, :show_earlier}, socket),
    do:
      {:noreply,
       socket |> Mob.Socket.assign(:window, socket.assigns.window + @window) |> refresh()}

  def handle_info({:tap, :new_session}, socket) do
    Loop.unsubscribe(socket.assigns.loop)
    {:noreply, attach(socket, Operator.Core.new_session())}
  end

  def handle_info({:tap, :edit_model}, socket) do
    draft = if socket.assigns.model_draft, do: nil, else: socket.assigns.model
    {:noreply, Mob.Socket.assign(socket, :model_draft, draft)}
  end

  def handle_info({:change, :model_draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :model_draft, value)}

  def handle_info({:tap, :save_model}, socket) do
    model = String.trim(socket.assigns.model_draft || "")
    model = if String.contains?(model, ":"), do: model, else: "openrouter:" <> model

    case Loop.set_model(socket.assigns.loop, model) do
      :ok ->
        {:noreply, Mob.Socket.assign(socket, model_draft: nil, model: model)}

      {:error, :running} ->
        {:noreply, toast(socket, "Can't change the model while the agent runs")}
    end
  end

  def handle_info({:tap, :diagnostics}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.HomeScreen)}

  def handle_info({:tap, :toggle_renderer}, socket) do
    Term.put_renderer(if Term.renderer() == :native, do: :term, else: :native)
    owner = self()
    done_rev = Enum.map(socket.assigns.done_rev, &message(&1.entry, &1.key, owner))
    {:noreply, socket |> Mob.Socket.assign(:done_rev, done_rev) |> refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── state ──

  defp attach(socket, loop) do
    :ok = Loop.subscribe(loop)
    snap = Loop.snapshot(loop)
    owner = self()

    {done_rev, next} =
      Enum.reduce(snap.entries, {[], 0}, fn entry, {acc, k} ->
        {[message(entry, "m#{k}", owner) | acc], k + 1}
      end)

    socket =
      Mob.Socket.assign(socket,
        loop: loop,
        sid: snap.session_id,
        model: snap.model,
        status: snap.status,
        detail: nil,
        queued: length(snap.queue.steering) + length(snap.queue.follow_up),
        totals: snap.totals,
        done_rev: done_rev,
        next_key: next,
        stream: nil,
        flush_timer: nil,
        following: true,
        last_offset: nil
      )

    socket =
      if snap.streaming, do: socket |> start_stream() |> buffer(snap.streaming), else: socket

    send(self(), :stick)
    refresh(socket)
  end

  # `key` ("m<n>") prefixes the message's row ids and tags its copy events.
  defp message(entry, key, owner),
    do: %{key: key, entry: entry, rows: Term.entry_rows(entry, key, owner)}

  defp on_event(%{type: :agent_start}, socket),
    do: Mob.Socket.assign(socket, status: :running, detail: nil)

  defp on_event(%{type: :agent_end}, socket),
    do: Mob.Socket.assign(socket, status: :idle, detail: nil, stream: nil)

  defp on_event(%{type: :message_start, entry: %{"message" => %{"role" => "assistant"}}}, socket),
    do: socket |> Mob.Socket.assign(:detail, "thinking…") |> start_stream()

  defp on_event(%{type: :message_update, kind: :text, delta: delta}, socket),
    do: buffer(socket, delta)

  defp on_event(%{type: :message_end, entry: entry}, socket) do
    {key, socket} =
      case {entry, socket.assigns.stream} do
        {%{"message" => %{"role" => "assistant"}}, %{key: key}} ->
          {key, cancel_flush(socket)}

        _ ->
          {"m#{socket.assigns.next_key}",
           Mob.Socket.assign(socket, :next_key, socket.assigns.next_key + 1)}
      end

    totals =
      case entry do
        %{"message" => %{"role" => "assistant", "usage" => %{} = u}} ->
          Session.add_usage(socket.assigns.totals, u)

        _ ->
          socket.assigns.totals
      end

    socket
    |> Mob.Socket.assign(
      stream: nil,
      totals: totals,
      done_rev: [message(entry, key, self()) | socket.assigns.done_rev]
    )
    |> repaint()
  end

  defp on_event(%{type: :retry, delay_ms: ms}, socket) do
    socket
    |> cancel_flush()
    |> Mob.Socket.assign(stream: nil, detail: "retrying in #{div(ms, 1000)}s…")
    |> refresh()
  end

  defp on_event(%{type: :tool_execution_start, name: name}, socket),
    do: Mob.Socket.assign(socket, :detail, "running #{name}…")

  defp on_event(%{type: :tool_execution_end}, socket), do: Mob.Socket.assign(socket, :detail, nil)

  defp on_event(%{type: :model_change, model: model}, socket),
    do: Mob.Socket.assign(socket, :model, model)

  defp on_event(%{type: :queue, steering: s, follow_up: f}, socket),
    do: Mob.Socket.assign(socket, :queued, length(s) + length(f))

  defp on_event(_event, socket), do: socket

  defp start_stream(socket) do
    k = socket.assigns.next_key
    stream = %{key: "m#{k}", acc: TermStream.new(), text: [], pending: []}
    Mob.Socket.assign(socket, stream: stream, next_key: k + 1)
  end

  # Deltas wait in `pending` until the next flush (at most every @flush_ms).
  defp buffer(%{assigns: %{stream: nil}} = socket, _delta), do: socket

  defp buffer(socket, delta) do
    st = socket.assigns.stream
    socket = Mob.Socket.assign(socket, :stream, %{st | pending: [st.pending, delta]})

    if socket.assigns.flush_timer,
      do: socket,
      else: Mob.Socket.assign(socket, :flush_timer, Process.send_after(self(), :flush, @flush_ms))
  end

  defp cancel_flush(%{assigns: %{flush_timer: nil}} = socket), do: socket

  defp cancel_flush(socket) do
    Process.cancel_timer(socket.assigns.flush_timer)
    Mob.Socket.assign(socket, :flush_timer, nil)
  end

  # New output: decide whether to follow (from how the list moved since the
  # last check), repaint, then scroll once the frame is in.
  defp repaint(socket) do
    %{following: following, last_offset: last} = socket.assigns
    {following, offset} = Follow.decide(Native.impl().scroll_info(@list_id), following, last)
    if following, do: Process.send_after(self(), :stick, @stick_ms)
    socket |> Mob.Socket.assign(following: following, last_offset: offset) |> refresh()
  end

  defp refresh(socket) do
    a = socket.assigns
    owner = self()
    stream_rows = if a.stream, do: Term.stream_rows(a.stream.acc, a.stream.key, owner), else: []
    {rows, hidden} = window(a.done_rev, stream_rows, a.window)
    earlier = if hidden > 0, do: [earlier_row(hidden)], else: []
    toast = if a.toast, do: [Term.notice_row(a.toast, "toast")], else: []
    Mob.Socket.assign(socket, :visible, earlier ++ rows ++ toast)
  end

  @doc false
  # The last `n` rows of the transcript, at most `max_native` of them native
  # views: finished messages (`done_rev`, newest first) followed by the
  # streaming reply's rows. Returns `{rows, hidden_count}`, rows in display
  # order.
  @spec window([map()], [map()], pos_integer(), pos_integer()) :: {[map()], non_neg_integer()}
  def window(done_rev, stream_rows, n, max_native \\ @max_native) do
    {rows, _budget, hidden} =
      Enum.reduce(
        done_rev,
        take_tail(stream_rows, {[], {n, max_native}, 0}),
        fn %{rows: rows}, acc -> take_tail(rows, acc) end
      )

    {rows, hidden}
  end

  # Prepends as many of `rows`' last rows as the budget allows; once it runs
  # out, everything older is hidden.
  defp take_tail(rows, {acc, {0, _} = budget, hidden}), do: {acc, budget, hidden + length(rows)}

  defp take_tail(rows, {acc, budget, hidden}) do
    rows
    |> Enum.reverse()
    |> Enum.reduce({acc, budget, hidden}, fn
      _row, {acc, {0, _} = budget, hidden} ->
        {acc, budget, hidden + 1}

      %{type: :native_view}, {acc, {_room, 0}, hidden} ->
        {acc, {0, 0}, hidden + 1}

      %{type: :native_view} = row, {acc, {room, natives}, hidden} ->
        {[row | acc], {room - 1, natives - 1}, hidden}

      row, {acc, {room, natives}, hidden} ->
        {[row | acc], {room - 1, natives}, hidden}
    end)
  end

  defp earlier_row(hidden) do
    t = Term.theme()

    %{
      type: :button,
      props: %{
        id: "earlier",
        text: "… show #{hidden} earlier lines",
        on_tap: {self(), :show_earlier},
        background: Term.color(t, "bar"),
        text_color: Term.color(t, "dim"),
        font: :term,
        text_size: t.text_size,
        fill_width: true
      },
      children: []
    }
  end

  defp send_draft(socket) do
    text = String.trim(socket.assigns.draft)

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.status == :running ->
        :ok = Loop.steer(socket.assigns.loop, text)
        {:noreply, Mob.Socket.assign(socket, draft: "", following: true)}

      true ->
        case Loop.prompt(socket.assigns.loop, text) do
          :ok -> :ok
          {:error, :running} -> Loop.steer(socket.assigns.loop, text)
        end

        {:noreply, Mob.Socket.assign(socket, draft: "", following: true)}
    end
  end

  defp copy(socket, text) when is_binary(text) and text != "" do
    case Native.impl().clipboard_put(text) do
      :ok -> toast(socket, "Copied #{String.length(text)} characters")
      {:error, _} -> toast(socket, "Copy failed: no clipboard")
    end
  end

  defp copy(socket, _nothing), do: toast(socket, "Nothing to copy")

  defp toast(socket, text) do
    Process.send_after(self(), :clear_toast, @toast_ms)
    socket |> Mob.Socket.assign(:toast, text) |> refresh()
  end

  # The full text of message `key` (`:plain` for the clipboard, `:raw` for markup).
  defp message_text(socket, key, mode) do
    case Enum.find(socket.assigns.done_rev, &(&1.key == key)) do
      %{entry: entry} when mode == :plain -> Term.plain_text(entry)
      %{entry: %{"message" => m}} -> Session.text(m["content"])
      %{entry: entry} -> Term.plain_text(entry)
      nil -> stream_text(socket.assigns.stream, key, mode)
    end
  end

  defp stream_text(%{key: key, text: text, pending: pending}, key, mode) do
    raw = IO.iodata_to_binary([text, pending])
    if mode == :plain, do: Markup.plain(raw), else: raw
  end

  defp stream_text(_stream, _key, _mode), do: nil

  defp assistant_text?(%{"message" => %{"role" => "assistant"} = m}),
    do: Session.text(m["content"]) != ""

  defp assistant_text?(_), do: false

  # ── chrome ──

  defp header(a, t) do
    # Status and cost first: the line is one row and gets cut at the end.
    model = a.model |> String.split("/") |> List.last()

    tokens =
      if a.totals.tokens >= 1000,
        do: "#{Float.round(a.totals.tokens / 1000, 1)}k",
        else: "#{a.totals.tokens}"

    queued = if a.queued > 0, do: " · #{a.queued} queued", else: ""
    cost = :erlang.float_to_binary(a.totals.cost, decimals: 4)
    line = "#{a.status}#{queued} · $#{cost} · #{tokens} tok · #{model}"

    bar_row(t, [
      text(line, t, "dim", weight: 1, max_lines: 1, text_size: t.text_size - 2),
      chip("new", :new_session, t),
      chip("model", :edit_model, t),
      chip("diag", :diagnostics, t),
      chip("md:#{Term.renderer(t)}", :toggle_renderer, t)
    ])
  end

  defp model_editor(%{model_draft: nil}, _t), do: []

  defp model_editor(a, t) do
    [
      bar_row(t, [
        field(a.model_draft, "openrouter:provider/model", :model_draft, t, weight: 1),
        chip("save", :save_model, t)
      ])
    ]
  end

  defp footer(a, t) do
    detail = a.detail || if(a.status == :running, do: "working…", else: "")

    bar_row(t, [
      text(detail, t, "dim",
        weight: 1,
        max_lines: 1,
        font: :term_italic,
        text_size: t.text_size - 2
      ),
      %{
        type: :text,
        props: %{
          text: "[copy last reply]",
          on_tap: {self(), :copy_last},
          font: :term,
          text_size: t.text_size - 2,
          text_color: Term.color(t, "accent")
        },
        children: []
      }
    ])
  end

  defp composer(a, t) do
    running = a.status == :running
    send_label = if running, do: "Steer", else: "Send"
    stop = if running, do: [chip("Stop", :stop, t, "error")], else: []

    bar_row(
      t,
      [
        field(a.draft, if(running, do: "› steer the agent…", else: "› ask Operator…"), :draft, t,
          weight: 1,
          on_submit: {self(), :draft}
        ),
        chip(send_label, :send, t, "user")
      ] ++ stop
    )
  end

  defp bar_row(t, children) do
    %{
      type: :row,
      props: %{
        fill_width: true,
        padding: 6,
        gap: 6,
        background: Term.color(t, "bar"),
        align: :center
      },
      children: children
    }
  end

  defp text(text, t, color, opts) do
    props =
      Map.merge(
        %{text: text, font: :term, text_size: t.text_size, text_color: Term.color(t, color)},
        Map.new(opts)
      )

    %{type: :text, props: props, children: []}
  end

  defp chip(label, tag, t, color \\ "fg") do
    %{
      type: :button,
      props: %{
        text: label,
        on_tap: {self(), tag},
        font: :term,
        text_size: t.text_size - 1,
        text_color: Term.color(t, color),
        background: Term.color(t, "code_bg"),
        padding: 6,
        fill_width: false
      },
      children: []
    }
  end

  defp field(value, placeholder, tag, t, opts) do
    props =
      Map.merge(
        %{
          value: value,
          placeholder: placeholder,
          on_change: {self(), tag},
          font: :term,
          text_size: t.text_size,
          text_color: Term.color(t, "fg"),
          placeholder_color: Term.color(t, "dim"),
          background: Term.color(t, "code_bg"),
          border_color: Term.color(t, "code_bg")
        },
        Map.new(opts)
      )

    %{type: :text_field, props: props, children: []}
  end
end
