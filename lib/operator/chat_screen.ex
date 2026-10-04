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

  On Android the composer has a mic (`Operator.Core.DictationButton`):
  hold it and talk; on release the phone transcribes it offline (`MobSpeech`
  with the `MobWhisper` engine; the chip shows "…" meanwhile) and the text
  lands in the draft (after what was already typed) to edit and send. `[voice:…]` cycles what the agent says
  aloud (`Operator.Core.Settings.voice/0`). The first send asks for the
  notification permission (the background-run notification needs it on
  Android 13+).

  A proposed self-change shows with its diff; on Android its approve chip
  is `Operator.Core.ApproveButton` (the system prompt: fingerprint, face,
  PIN, pattern or password), whose pass activates it.

  `/login anthropic`, `/login openai`, `/login anthropic <code#state>` and
  `/logout <provider>` are the app's own commands (`Operator.Auth.Login`,
  `Operator.Auth`): they never reach the model, and their results show as
  notices.

  `operator://` links scanned on the Mac's QR codes (`Operator.Links`)
  come here: a handoff's parts are collected, and the last one switches to
  a new session that opens with the handoff (the model sees it with the
  next prompt); a login link opens `Operator.LoginScanScreen` at the words.
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.Auth.Login
  alias Operator.ChatScreen.Follow
  alias Operator.ChatScreen.Native
  alias Operator.Core.ApproveButton
  alias Operator.Core.DictationButton
  alias Operator.Core.Dyn
  alias Operator.Core.DynTheme
  alias Operator.Core.Loop
  alias Operator.Core.Models
  alias Operator.Core.Phone
  alias Operator.Core.Session
  alias Operator.Core.Settings
  alias Operator.Core.Term
  alias Operator.Core.Term.Markup
  alias Operator.Core.Term.Stream, as: TermStream
  alias Operator.Links

  @flush_ms 100
  @stick_ms 60
  @stick_retries 4
  @stick_retry_ms 150
  @attach_stick_ms 300
  @header_chip_size 12
  @toast_ms 1_500
  @window 300
  @max_native 200
  @proposal_diff_lines 200
  @list_id "transcript"

  def mount(params, _session, socket) do
    loop = Map.get(params, :loop) || Operator.Core.current()
    settings_dir = Map.get(params, :settings_dir) || Operator.Paths.data_dir()
    _ = Dyn.subscribe()
    :ok = Phone.register_host(self())
    :ok = DynTheme.subscribe()
    if Process.whereis(Mob.Device), do: Mob.Device.subscribe(:app)
    # A link Diagnostics received: it forwards them here.
    with %{link: link} <- params, do: send(self(), {:operator_link, link})
    # Dictation's offline speech model: fetched once, then loaded in the
    # background so the first hold doesn't wait for it.
    if Term.platform() == :android, do: MobWhisper.prefetch(notify: self())

    {:ok,
     socket
     |> Mob.Socket.assign(window: @window, draft: "", model_draft: nil, toast: nil)
     |> Mob.Socket.assign(
       settings_dir: settings_dir,
       voice: Settings.voice(settings_dir),
       dictation_base: nil,
       dictation: :idle,
       notifications_asked: false,
       proposal: pending_proposal(),
       activated: nil,
       phone: %{},
       foreground: true,
       model_picker: false
     )
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
            footer(assigns, t)
          ] ++
          approval_bar(assigns, t) ++
          [
            composer(assigns, t)
          ] ++ model_sheet(assigns, t)
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

  def handle_info(:stick, socket), do: handle_info({:stick, @stick_retries}, socket)

  # Native rows get their height only once laid out, and right after mount
  # the list isn't even registered yet, so a stick can land short of the
  # end or not happen: check, and retry a few times while following.
  def handle_info({:stick, retries}, socket) do
    native = Native.impl()

    if socket.assigns.following do
      with %{} = info <- native.scroll_info(@list_id) do
        {x, y} = Follow.bottom(info)
        native.scroll_to(@list_id, x, y)
      end

      if retries > 0 and short_of_end?(native.scroll_info(@list_id)),
        do: Process.send_after(self(), {:stick, retries - 1}, @stick_retry_ms)
    end

    {:noreply, socket}
  end

  # Only the toast it was set for: a newer one keeps its full time.
  def handle_info({:clear_toast, text}, %{assigns: %{toast: text}} = socket),
    do: {:noreply, socket |> Mob.Socket.assign(:toast, nil) |> refresh()}

  def handle_info({:clear_toast, _older}, socket), do: {:noreply, socket}

  # ── composer ──

  def handle_info({:change, :draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info({:submit, :draft}, socket), do: send_draft(socket)
  def handle_info({:tap, :send}, socket), do: send_draft(socket)

  def handle_info({:tap, :stop}, socket) do
    Loop.stop(socket.assigns.loop)
    {:noreply, socket}
  end

  # ── dictation (Operator.Core.DictationButton → MobSpeech, whisper engine) ──

  def handle_info({:dictation, "press", _}, socket) do
    {engine, opts} = dictation_engine()
    socket = MobSpeech.listen(socket, [engine: engine] ++ opts)
    {:noreply, Mob.Socket.assign(socket, :dictation, :listening)}
  end

  def handle_info({:dictation, "release", _}, socket),
    do: {:noreply, MobSpeech.stop(socket)}

  def handle_info({:dictation, "cancel", _}, socket) do
    socket = socket |> MobSpeech.cancel() |> toast("Hold mic while you talk; let go to stop")
    {:noreply, socket}
  end

  def handle_info({:dictation, "needs_permission", _}, socket) do
    Native.impl().request_permission(:microphone)
    {:noreply, toast(socket, "Allow the microphone, then hold mic and talk")}
  end

  def handle_info({:dictation, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:speech, :state, :listening}, socket) do
    {:noreply,
     Mob.Socket.assign(socket, dictation: :listening, dictation_base: dictation_base(socket))}
  end

  def handle_info({:speech, :state, :processing}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :dictation, :processing)}

  def handle_info({:speech, :state, :idle}, socket),
    do: {:noreply, Mob.Socket.assign(socket, dictation: :idle, dictation_base: nil)}

  def handle_info({:speech, :partial, text}, socket) do
    base = dictation_base(socket)
    {:noreply, Mob.Socket.assign(socket, draft: append(base, text), dictation_base: base)}
  end

  # Dictation never sends: the text waits in the draft to be edited.
  def handle_info({:speech, :final, text}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, append(dictation_base(socket), text))}

  def handle_info({:speech, :error, reason}, socket),
    do: {:noreply, toast(socket, dictation_error(reason))}

  # The speech model downloads once (MobWhisper.prefetch/1 at mount).
  def handle_info({:mob_whisper, :model, :ready}, socket), do: {:noreply, socket}

  def handle_info({:mob_whisper, :model, {:error, reason}}, socket),
    do: {:noreply, toast(socket, model_error(reason))}

  def handle_info({:permission, :microphone, :granted}, socket),
    do: {:noreply, toast(socket, "Microphone allowed: hold mic and talk")}

  def handle_info({:permission, :microphone, _denied}, socket),
    do: {:noreply, toast(socket, "No microphone access: allow it in Settings to dictate")}

  def handle_info({:permission, capability, result}, socket)
      when capability in [:location, :camera] do
    action = if capability == :location, do: :location, else: :camera_photo

    case socket.assigns.phone do
      %{^action => {_ref, _from, args}} when result == :granted ->
        :ok = Native.impl().phone(action, args)
        {:noreply, socket}

      %{^action => {ref, from, _args}} ->
        Phone.reply(from, ref, {:error, "The user didn't allow #{capability} access."})
        {:noreply, Mob.Socket.assign(socket, :phone, Map.delete(socket.assigns.phone, action))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:permission, _capability, _result}, socket), do: {:noreply, socket}

  # ── phone actions for tools (Operator.Core.Phone) ──

  # The camera and the photo picker are activities: Android won't start them
  # from an app in the background, so those requests need Operator in front.
  def handle_info({:mob_device, event}, socket)
      when event in [:will_resign_active, :did_enter_background],
      do: {:noreply, Mob.Socket.assign(socket, :foreground, false)}

  def handle_info({:mob_device, :did_become_active}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :foreground, true)}

  def handle_info({:mob_device, _event}, socket), do: {:noreply, socket}

  def handle_info(
        {:phone_request, ref, from, action, _args},
        %{assigns: %{foreground: false}} = socket
      )
      when action in [:camera_photo, :pick_photos] do
    Phone.reply(
      from,
      ref,
      {:error, "Operator isn't on screen; ask the user to open it, then try again."}
    )

    {:noreply, socket}
  end

  def handle_info({:phone_request, ref, from, action, args}, socket) do
    case socket.assigns.phone do
      %{^action => {_ref, waiting, _args}} ->
        if Process.alive?(waiting) do
          Phone.reply(from, ref, {:error, "Another #{action} request is still waiting."})
          {:noreply, socket}
        else
          start_phone(socket, ref, from, action, args)
        end

      _ ->
        start_phone(socket, ref, from, action, args)
    end
  end

  def handle_info({:location, %{} = fix}, socket),
    do: {:noreply, phone_done(socket, :location, {:ok, fix})}

  def handle_info({:location, :error, reason}, socket),
    do: {:noreply, phone_done(socket, :location, {:error, "No location: #{inspect(reason)}"})}

  def handle_info({:camera, :photo, %{} = photo}, socket),
    do: {:noreply, phone_done(socket, :camera_photo, {:ok, photo})}

  def handle_info({:camera, :cancelled}, socket),
    do: {:noreply, phone_done(socket, :camera_photo, {:ok, :cancelled})}

  def handle_info({:photos, :picked, items}, socket),
    do: {:noreply, phone_done(socket, :pick_photos, {:ok, items})}

  def handle_info({:photos, :cancelled}, socket),
    do: {:noreply, phone_done(socket, :pick_photos, {:ok, :cancelled})}

  # ── voice ──

  def handle_info({:tap, :cycle_voice}, socket) do
    voices = Settings.voices()

    next =
      Enum.at(
        voices,
        rem(Enum.find_index(voices, &(&1 == socket.assigns.voice)) + 1, length(voices))
      )

    :ok = Settings.put_voice(next, socket.assigns.settings_dir)
    {:noreply, socket |> Mob.Socket.assign(:voice, next) |> toast("Voice: #{voice_hint(next)}")}
  end

  # ── self-modification proposals (Operator.Core.Dyn) ──

  def handle_info({:operator_dyn, %{type: :candidate, gen: n}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:proposal, proposal(n)) |> repaint()}

  def handle_info({:operator_dyn, event}, socket) do
    gone =
      event[:type] in [:superseded, :discarded, :activated] and
        match?(%{gen: _}, socket.assigns.proposal) and socket.assigns.proposal.gen == event[:gen]

    socket = if gone, do: Mob.Socket.assign(socket, :proposal, nil), else: socket

    # This screen just activated it and said so already.
    own = event[:type] == :activated and event[:gen] == socket.assigns.activated

    case if(own, do: nil, else: dyn_line(event)) do
      nil -> {:noreply, refresh(socket)}
      line -> {:noreply, toast(socket, line)}
    end
  end

  # Off Android there's no screen-lock prompt: the plain chip asks for a
  # token unconfirmed, which only an approval needing no confirmation (the
  # tests') grants.
  def handle_info({:tap, :approve_proposal}, %{assigns: %{proposal: %{gen: n}}} = socket),
    do: {:noreply, activate(socket, n)}

  def handle_info({:tap, :deny_proposal}, %{assigns: %{proposal: %{gen: n}}} = socket) do
    case Dyn.discard(n) do
      :ok ->
        {:noreply,
         socket |> Mob.Socket.assign(:proposal, nil) |> toast("Proposal #{n} discarded")}

      {:error, reason} ->
        {:noreply, toast(socket, "Couldn't discard proposal #{n}: #{inspect(reason)}")}
    end
  end

  def handle_info({:tap, tag}, socket) when tag in [:approve_proposal, :deny_proposal],
    do: {:noreply, Mob.Socket.assign(socket, :proposal, nil) |> refresh()}

  # ── the approve chip (Operator.Core.ApproveButton) ──

  def handle_info({:approval, "approved", %{"subject" => {:activate, n} = subject}}, socket) do
    case Native.impl().confirm_approval(subject) do
      :ok -> {:noreply, activate(socket, n)}
      {:error, reason} -> {:noreply, not_activated(socket, n, inspect(reason))}
    end
  end

  def handle_info({:approval, "failed", %{"subject" => {:activate, n}} = payload}, socket),
    do: {:noreply, not_activated(socket, n, ApproveButton.why("failed", payload))}

  def handle_info({:approval, "unavailable", payload}, socket),
    do: {:noreply, toast(socket, ApproveButton.why("unavailable", payload))}

  def handle_info({:approval, _event, _payload}, socket), do: {:noreply, socket}

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
    socket = detach(socket)
    {:noreply, attach(socket, Operator.Core.new_session())}
  end

  # The model chip (and `/models`) opens the list of models you can use;
  # "Custom…" there opens the text field for anything else.
  def handle_info({:tap, :edit_model}, socket),
    do: {:noreply, Mob.Socket.assign(socket, model_picker: true, model_draft: nil)}

  def handle_info({:tap, :close_models}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :model_picker, false)}

  def handle_info({:tap, :custom_model}, socket),
    do:
      {:noreply,
       Mob.Socket.assign(socket, model_picker: false, model_draft: socket.assigns.model)}

  def handle_info({:tap, {:pick_model, spec}}, socket) do
    socket = Mob.Socket.assign(socket, :model_picker, false)

    case Loop.set_model(socket.assigns.loop, spec) do
      :ok ->
        {:noreply, Mob.Socket.assign(socket, :model, spec)}

      {:error, :running} ->
        {:noreply, toast(socket, "Can't change the model while the agent runs")}
    end
  end

  def handle_info({:change, :model_draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :model_draft, value)}

  # A session file brought over from omp (scripts/session.sh push).
  def handle_info({:open_session, path}, socket) do
    case Operator.Core.open_session(path) do
      {:ok, loop} ->
        {:noreply, socket |> detach() |> attach(loop) |> toast("Opened #{Path.basename(path)}")}

      {:error, reason} ->
        {:noreply, toast(socket, "Couldn't open #{Path.basename(path)}: #{inspect(reason)}")}
    end
  end

  def handle_info({:tap, :save_model}, socket) do
    model = String.trim(socket.assigns.model_draft || "")
    model = if String.contains?(model, ":"), do: model, else: Session.from_pi_model(model)

    case Loop.set_model(socket.assigns.loop, model) do
      :ok ->
        {:noreply, Mob.Socket.assign(socket, model_draft: nil, model: model)}

      {:error, :running} ->
        {:noreply, toast(socket, "Can't change the model while the agent runs")}
    end
  end

  # ── sign-in (`/login`, Operator.Auth.Login) ──

  def handle_info({:operator_login, provider, :ok}, socket) do
    who =
      case Auth.get(provider) do
        {:ok, %{"email" => email}} -> " as #{email}"
        _ -> ""
      end

    {:noreply, lasting_toast(socket, "Signed in to #{Auth.label(provider)}#{who}.")}
  end

  def handle_info({:operator_login, provider, {:error, message}}, socket),
    do: {:noreply, lasting_toast(socket, "Sign-in to #{Auth.label(provider)} failed: #{message}")}

  # ── operator:// links (Operator.Links) ──

  # Scanned with another app, a link arrives as mob's {:link, ...}
  # (Mob.Link); Diagnostics forwards its own through `mount/3`. The scan
  # happens with that app in front, so the toasts last.
  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: handle_info({:operator_link, link}, socket)

  def handle_info({:operator_link, link}, socket) do
    case Links.handle(link) do
      {:handoff_part, received, total} ->
        {:noreply,
         lasting_toast(socket, "Handoff #{received} of #{total} received: scan the rest")}

      {:handoff, handoff, loop} ->
        socket = socket |> detach() |> attach(loop)
        {:noreply, lasting_toast(socket, "Handoff#{titled(handoff)} received: say what's next")}

      {:login, link} ->
        {:noreply, Mob.Socket.push_screen(socket, Operator.LoginScanScreen, %{link: link})}

      {:deliver, endpoint} ->
        {:noreply, Mob.Socket.push_screen(socket, Operator.LoginScanScreen, %{deliver: endpoint})}

      {:error, text} ->
        {:noreply, lasting_toast(socket, text)}
    end
  end

  def handle_info({:tap, :diagnostics}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.HomeScreen)}

  def handle_info({:tap, :toggle_renderer}, socket) do
    Term.put_renderer(if Term.renderer() == :native, do: :term, else: :native)
    {:noreply, rerender(socket)}
  end

  # A Dyn generation changed the theme (Operator.Core.DynTheme): rows have
  # its colours baked in.
  def handle_info({:operator_theme, :changed}, socket), do: {:noreply, rerender(socket)}

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

    # The first runs before the new transcript reaches the native list (it
    # may scroll the old one to its end, which counts as done); the second
    # once the new rows are laid out.
    send(self(), :stick)
    Process.send_after(self(), :stick, @attach_stick_ms)
    refresh(socket)
  end

  # Stops following the shown loop. Current stops it when it starts another
  # session, so it may be gone already.
  defp detach(socket) do
    Loop.unsubscribe(socket.assigns.loop)
    socket
  catch
    :exit, _ -> socket
  end

  defp titled(%{title: title}) when is_binary(title), do: " (#{title})"
  defp titled(_handoff), do: ""

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

  defp on_event(%{type: :compaction_start}, socket) do
    socket
    |> cancel_flush()
    |> Mob.Socket.assign(stream: nil, detail: "compacting context…")
    |> refresh()
  end

  # The compaction notice joins the transcript like any finished entry.
  defp on_event(%{type: :compaction, entry: entry}, socket),
    do: on_event(%{type: :message_end, entry: entry}, Mob.Socket.assign(socket, :detail, nil))

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

  # Unknown (no list yet) or reported not at the end; a list that doesn't
  # report `at_end` (iOS pixel views) is taken as done.
  defp short_of_end?(%{at_end: at_end}), do: not at_end
  defp short_of_end?(%{}), do: false
  defp short_of_end?(_unavailable), do: true

  defp rerender(socket) do
    owner = self()
    done_rev = Enum.map(socket.assigns.done_rev, &message(&1.entry, &1.key, owner))
    socket |> Mob.Socket.assign(:done_rev, done_rev) |> refresh()
  end

  defp refresh(socket) do
    a = socket.assigns
    owner = self()
    stream_rows = if a.stream, do: Term.stream_rows(a.stream.acc, a.stream.key, owner), else: []
    {rows, hidden} = window(a.done_rev, stream_rows, a.window)
    earlier = if hidden > 0, do: [earlier_row(hidden)], else: []
    toast = if a.toast, do: [Term.notice_row(a.toast, "toast")], else: []

    proposal =
      if a.proposal, do: Term.entry_rows(a.proposal.entry, a.proposal.key, owner), else: []

    Mob.Socket.assign(socket, :visible, earlier ++ rows ++ proposal ++ toast)
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

      command?(text) ->
        {:noreply,
         socket |> Mob.Socket.assign(:draft, "") |> command(String.split(text, ~r/\s+/, parts: 3))}

      socket.assigns.status == :running ->
        :ok = Loop.steer(socket.assigns.loop, text)
        {:noreply, Mob.Socket.assign(socket, draft: "", following: true)}

      true ->
        case Loop.prompt(socket.assigns.loop, text) do
          :ok -> :ok
          {:error, :running} -> Loop.steer(socket.assigns.loop, text)
        end

        {:noreply, socket |> ask_notifications() |> Mob.Socket.assign(draft: "", following: true)}
    end
  end

  # `/login`, `/logout` and `/models` are the app's: they never reach the model.
  defp command?(text), do: Regex.match?(~r{^/(log(in|out)|models)(\s|$)}, text)

  defp command(socket, ["/models" | _]), do: Mob.Socket.assign(socket, :model_picker, true)

  defp command(socket, ["/login", name]) do
    with {:ok, provider} <- Auth.parse_provider(name),
         {:ok, url} <- Login.begin(provider) do
      host = URI.parse(url).host
      lasting_toast(socket, "Opening #{host}: sign in there, then come back to Operator.")
    else
      :error -> toast(socket, login_usage())
      {:error, reason} -> toast(socket, "Couldn't start the sign-in: #{inspect(reason)}")
    end
  end

  # What Anthropic's page shows when it doesn't redirect back (`code#state`).
  defp command(socket, ["/login", name, pasted]) do
    with {:ok, provider} <- Auth.parse_provider(name),
         :ok <- Login.paste(provider, pasted) do
      lasting_toast(socket, "Code received: finishing the sign-in…")
    else
      :error -> toast(socket, login_usage())
      {:error, reason} -> toast(socket, paste_error(reason, name))
    end
  end

  defp command(socket, ["/logout", name]) do
    case Auth.parse_provider(name) do
      {:ok, provider} -> logout(socket, provider)
      :error -> toast(socket, login_usage())
    end
  end

  defp command(socket, _usage), do: lasting_toast(socket, login_usage())

  defp logout(socket, provider) do
    case Auth.delete(provider) do
      :ok ->
        toast(socket, "Signed out of #{Auth.label(provider)}.")

      {:error, reason} ->
        lasting_toast(
          socket,
          "Couldn't sign out of #{Auth.label(provider)} (#{Auth.describe_error(reason)}): " <>
            "it is still signed in."
        )
    end
  end

  defp login_usage do
    signed_in =
      for {provider, %{signed_in: true} = st} <- Auth.status() do
        Auth.name(provider) <> if(st.email, do: " (#{st.email})", else: "")
      end

    "/login anthropic (Claude Pro/Max) or /login openai (ChatGPT Plus/Pro); " <>
      "/logout <provider>. Signed in: " <>
      if(signed_in == [], do: "none", else: Enum.join(signed_in, ", "))
  end

  defp paste_error(:no_login_started, name),
    do: "Type /login #{name} first, then paste the code its page shows."

  defp paste_error({:started_for, other}, name),
    do: "The sign-in in progress is for #{Auth.name(other)}: type /login #{name} again."

  defp paste_error(:state_mismatch, name),
    do: "That code is from another sign-in: type /login #{name} again."

  defp paste_error(:no_code, _name),
    do: "No code in that: paste what the page shows (code#state)."

  # News that arrives while another app is in front (the browser during a
  # sign-in, a QR app during a handoff) stays up long enough to be seen on
  # return.
  defp lasting_toast(socket, text) do
    Process.send_after(self(), {:clear_toast, text}, 20_000)
    socket |> Mob.Socket.assign(:toast, text) |> repaint()
  end

  # Once per screen: a run may go on in the background, and its notification
  # needs this on Android 13+ (granted without asking before that).
  defp ask_notifications(%{assigns: %{notifications_asked: true}} = socket), do: socket

  defp ask_notifications(socket) do
    Native.impl().request_permission(:notifications)
    Mob.Socket.assign(socket, :notifications_asked, true)
  end

  # Dictation lands after what was in the draft when it started.
  defp dictation_base(socket), do: socket.assigns.dictation_base || socket.assigns.draft

  @doc false
  # The draft with dictated `text` after `base` (one space between).
  @spec append(String.t(), String.t()) :: String.t()
  def append(base, text) do
    case {String.trim_trailing(base), String.trim(text)} do
      {"", said} -> said
      {_typed, ""} -> base
      {typed, said} -> typed <> " " <> said
    end
  end

  # The engine and its options: Whisper on the phone (the platform recognizer
  # depends on the Google app's language packs and returns nothing without
  # them); tests script MobSpeech.Engine.Fake.
  defp dictation_engine, do: Application.get_env(:operator, :dictation_engine, {MobWhisper, []})

  defp dictation_error(:no_speech), do: "Didn't catch that: hold mic while you speak"

  defp dictation_error(:network),
    do: "The speech model isn't downloaded yet: connect to the internet and try again"

  defp dictation_error(:unavailable), do: "Speech to text isn't available in this build"
  defp dictation_error(:language), do: "The speech model only understands English"
  defp dictation_error(:busy), do: "Still transcribing the last one: try again"

  defp dictation_error(:permission),
    do: "No microphone access: allow it in Settings to dictate"

  defp dictation_error(:audio), do: "The microphone stopped (headset change?): try again"
  defp dictation_error(reason), do: "Dictation failed (#{inspect(reason)})"

  defp model_error(:network),
    do: "Couldn't download the speech model (60 MB): dictation needs it once"

  defp model_error(reason), do: "The speech model didn't load (#{inspect(reason)})"

  defp voice_hint(:off), do: "silent"
  defp voice_hint(:important), do: "speaks when a run ends"
  defp voice_hint(:everything), do: "speaks every reply"

  # Location and camera ask for their permission first (the answer starts
  # the action, `{:permission, ...}` above); a notification is scheduled at
  # once and answered with its id.
  defp start_phone(socket, ref, from, :notify, args) do
    id = "operator-#{System.unique_integer([:positive])}"

    result =
      case Native.impl().phone(:notify, Map.put(args, :id, id)) do
        :ok -> {:ok, id}
        {:error, reason} -> {:error, "Couldn't schedule it: #{inspect(reason)}"}
      end

    Phone.reply(from, ref, result)
    {:noreply, socket}
  end

  defp start_phone(socket, ref, from, action, args) do
    socket =
      Mob.Socket.assign(socket, :phone, Map.put(socket.assigns.phone, action, {ref, from, args}))

    case action do
      :location -> Native.impl().request_permission(:location)
      :camera_photo -> Native.impl().request_permission(:camera)
      :pick_photos -> Native.impl().phone(:pick_photos, args)
    end

    {:noreply, socket}
  end

  defp phone_done(socket, action, result) do
    case Map.pop(socket.assigns.phone, action) do
      {{ref, from, _args}, rest} ->
        Phone.reply(from, ref, result)
        Mob.Socket.assign(socket, :phone, rest)

      {nil, _} ->
        socket
    end
  end

  # The pending candidate when the screen mounts (a proposal made while it
  # was away still shows).
  defp pending_proposal do
    case Dyn.status() do
      %{pending: n} when is_integer(n) -> proposal(n)
      _ -> nil
    end
  end

  # The proposal as a reply-like transcript block: rationale, selftests,
  # the diff (as a `diff` code block, so it can be copied).
  defp proposal(n) do
    case Dyn.generation(n) do
      {:ok, gen} ->
        tests = gen.selftests
        passed = Enum.count(tests, & &1.ok)
        diff = n |> Dyn.diff() |> String.split("\n") |> cap_lines(@proposal_diff_lines)

        md =
          "**Proposal: generation #{n}**: #{gen.rationale}\n\n" <>
            "#{passed}/#{length(tests)} selftests passed · compiled in #{gen.compile_ms || "?"} ms\n\n" <>
            "```diff\n#{diff}\n```\n\n" <>
            "Approve below (fingerprint, face, PIN, pattern or password), or deny it."

        entry = %{
          "type" => "message",
          "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => md}]}
        }

        %{gen: n, key: "p#{n}", entry: entry}

      _ ->
        nil
    end
  end

  defp cap_lines(lines, max) when length(lines) <= max, do: Enum.join(lines, "\n")

  defp cap_lines(lines, max),
    do: Enum.join(Enum.take(lines, max), "\n") <> "\n… #{length(lines) - max} more lines"

  defp proposal_message(%{assigns: %{proposal: %{key: key, entry: entry}}}),
    do: [%{key: key, entry: entry}]

  defp proposal_message(_socket), do: []

  defp activate(socket, n) do
    with {:ok, token} <- Dyn.request_approval({:activate, n}),
         {:ok, _gen} <- Dyn.activate(n, token) do
      socket
      |> Mob.Socket.assign(proposal: nil, activated: n)
      |> toast("Generation #{n} is live, on probation: it reverts by itself if it keeps crashing")
    else
      {:error, :approval_required} ->
        not_activated(socket, n, "it needs approving through the phone's screen-lock prompt")

      {:error, reason} ->
        not_activated(socket, n, inspect(reason))
    end
  end

  defp not_activated(socket, n, why), do: toast(socket, "Generation #{n} not activated: #{why}")

  defp dyn_line(%{type: :activated, gen: n}), do: "Generation #{n} activated (on probation)"
  defp dyn_line(%{type: :proven, gen: n}), do: "Generation #{n} is proven"
  defp dyn_line(%{type: :superseded, gen: n}), do: "Proposal #{n} superseded by a newer one"
  defp dyn_line(%{type: :discarded}), do: nil

  defp dyn_line(%{type: :reverted, from: from, to: to} = e),
    do: "Generation #{from} reverted to #{to}: #{e[:reason] || "crashing"}"

  defp dyn_line(%{type: :crash} = e), do: "A Dyn module crashed (generation #{e[:gen] || "?"})"
  defp dyn_line(%{type: :safe_mode}), do: "Safe mode: the Dyn layer isn't loaded this launch"
  defp dyn_line(%{type: :load_failed, gen: n}), do: "Generation #{n} failed to load"
  defp dyn_line(_event), do: nil

  defp copy(socket, text) when is_binary(text) and text != "" do
    case Native.impl().clipboard_put(text) do
      :ok -> toast(socket, "Copied #{String.length(text)} characters")
      {:error, _} -> toast(socket, "Copy failed: no clipboard")
    end
  end

  defp copy(socket, _nothing), do: toast(socket, "Nothing to copy")

  # The toast is the transcript's last row: repaint, so a following list
  # scrolls it into view (and one the user scrolled up stays put). Longer
  # text stays longer (~20 characters a second).
  defp toast(socket, text) do
    Process.send_after(self(), {:clear_toast, text}, max(@toast_ms, String.length(text) * 50))
    socket |> Mob.Socket.assign(:toast, text) |> repaint()
  end

  # The full text of message `key` (`:plain` for the clipboard, `:raw` for markup).
  defp message_text(socket, key, mode) do
    case Enum.find(socket.assigns.done_rev ++ proposal_message(socket), &(&1.key == key)) do
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
    model = a.model |> String.split(["/", ":"]) |> List.last()

    tokens =
      if a.totals.tokens >= 1000,
        do: "#{Float.round(a.totals.tokens / 1000, 1)}k",
        else: "#{a.totals.tokens}"

    queued = if a.queued > 0, do: " · #{a.queued} queued", else: ""
    cost = :erlang.float_to_binary(a.totals.cost, decimals: 4)
    line = "#{a.status}#{queued} · $#{cost} · #{tokens} tok · #{model}"

    bar_row(t, [
      text(line, t, "dim", weight: 1, max_lines: 1, text_size: t.text_size - 2),
      header_chip("new", :new_session, t),
      header_chip("model", :edit_model, t),
      header_chip("diag", :diagnostics, t),
      header_chip("md:#{Term.renderer(t)}", :toggle_renderer, t)
    ])
  end

  defp model_sheet(%{model_picker: false}, _t), do: []

  # The models you can use now (Operator.Core.Models), by provider; the
  # current one marked. Tapping one switches this session to it.
  defp model_sheet(a, t) do
    rows =
      Enum.flat_map(Models.by_provider(), fn {provider, signed_in, models} ->
        heading = text(Auth.label(provider), t, "dim", text_size: t.text_size - 1)

        body =
          if signed_in,
            do: Enum.map(models, &model_row(&1, a.model, t)),
            else: [
              text("/login #{Auth.name(provider)} to add these", t, "dim", font: :term_italic)
            ]

        [heading | body] ++ [%{type: :spacer, props: %{size: 12}, children: []}]
      end)

    custom = %{
      type: :text,
      props: %{
        text: "Custom model…",
        on_tap: {self(), :custom_model},
        font: :term,
        text_size: t.text_size,
        text_color: Term.color(t, "accent"),
        padding: 10
      },
      children: []
    }

    [
      Mob.UI.sheet(
        %{
          type: :scroll,
          props: %{fill_width: true, background: Term.color(t, "bar")},
          children: [
            %{
              type: :column,
              props: %{fill_width: true, padding: 12, background: Term.color(t, "bar")},
              children: rows ++ [custom]
            }
          ]
        },
        detents: [:medium, :large],
        on_dismiss: {self(), :close_models},
        background: Term.color(t, "bar")
      )
    ]
  end

  defp model_row(model, current, t) do
    chosen = Models.same?(model.spec, current)
    context = if model.context, do: "  " <> context_label(model.context), else: ""

    %{
      type: :text,
      props: %{
        text: if(chosen, do: "● ", else: "  ") <> model.name <> context,
        on_tap: {self(), {:pick_model, model.spec}},
        font: if(chosen, do: :term_bold, else: :term),
        text_size: t.text_size,
        text_color: Term.color(t, if(chosen, do: "user", else: "fg")),
        padding: 6,
        fill_width: true
      },
      children: []
    }
  end

  defp context_label(tokens) when tokens >= 1_000_000 and rem(tokens, 1_000_000) == 0,
    do: "#{div(tokens, 1_000_000)}M"

  defp context_label(tokens), do: "#{div(tokens, 1000)}k"

  defp model_editor(%{model_draft: nil}, _t), do: []

  defp model_editor(a, t) do
    [
      bar_row(t, [
        field(a.model_draft, "anthropic:… or openai_codex:…", :model_draft, t, weight: 1),
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
      footer_link("[voice:#{a.voice}]", :cycle_voice, t),
      footer_link("[copy last reply]", :copy_last, t)
    ])
  end

  defp footer_link(label, tag, t) do
    %{
      type: :text,
      props: %{
        text: label,
        on_tap: {self(), tag},
        font: :term,
        text_size: t.text_size - 2,
        text_color: Term.color(t, "accent")
      },
      children: []
    }
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
        )
      ] ++ mic(a.dictation, t) ++ [chip(send_label, :send, t, "user")] ++ stop
    )
  end

  # Speech to text; only Android has the native view so far. `phase` shows
  # "…" on the chip while Whisper transcribes (it has no partial results).
  defp mic(phase, t) do
    if Term.platform() == :android do
      [
        Mob.UI.native_view(DictationButton,
          id: :dictation,
          notify: self(),
          phase: Atom.to_string(phase),
          text_color: Term.color(t, "fg"),
          active_color: Term.color(t, "error"),
          background: Term.color(t, "code_bg"),
          text_size: t.text_size - 1,
          font: Term.markdown_props(t).font_regular
        )
      ]
    else
      []
    end
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

  defp approval_bar(%{proposal: %{gen: n}}, t) do
    [
      bar_row(t, [
        text("proposal G#{n}", t, "accent",
          weight: 1,
          max_lines: 1,
          text_size: t.text_size - 1
        ),
        approve_chip(n, t),
        chip("deny", :deny_proposal, t, "error")
      ])
    ]
  end

  defp approval_bar(_a, _t), do: []

  # The system screen-lock prompt; only Android has the native view so far.
  defp approve_chip(n, t) do
    if Term.platform() == :android do
      Mob.UI.native_view(ApproveButton,
        id: :approve_proposal,
        notify: self(),
        subject: {:activate, n},
        label: "approve",
        title: "Activate generation #{n}",
        subtitle: "Operator changes its own code",
        text_color: Term.color(t, "user"),
        background: Term.color(t, "code_bg"),
        text_size: t.text_size - 1,
        font: Term.markdown_props(t).font_regular
      )
    else
      chip("approve", :approve_proposal, t, "user")
    end
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

  # The header has four chips in one row: a theme's bigger text mustn't push
  # them off the screen (seen at text_size 15).
  defp header_chip(label, tag, t),
    do: put_in(chip(label, tag, t), [:props, :text_size], min(t.text_size - 1, @header_chip_size))

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
