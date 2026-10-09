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

  Tapping the composer's field opens it over the screen above the keyboard:
  the transcript shrinks to a sliver under the status line showing its last
  #{2} lines, live, and the composer gets a tall multi-line field (it
  scrolls), the [attach] chips, mic, Send/Steer and Stop. `[hide]` closes it
  and keeps the draft; sending closes it too. The field keeps its id and
  place in the tree across the two layouts, so the focus (and the keyboard)
  the tap gave it carries over; closing renders it under a new id, which
  drops the focus and the keyboard.

  Long-press a line to copy its whole message (native Markdown rows select
  text instead: long-press, drag the handles, Copy); `[copy]` on a code
  fence copies that block; "copy last reply" copies the last assistant
  message.

  The top bar is `[frontend]` (to the front, `Operator.Toggle`), `[menu]`
  (`Operator.MenuScreen`: sign-ins, the model, new and past sessions, the
  renderer, diagnostics) and the status line. The menu tells this screen
  about a new or resumed session and a renderer change with
  `{:operator_menu, action}`; a model change arrives as the loop's own
  event. While no provider is signed in, the transcript ends with a line
  saying where to sign in. The composer only talks to the agent: there are
  no chat commands.

  `[attach]` beside the mic opens `[photo library] [take photo] [file]`:
  the same picks the agent's tools make (`Operator.Core.Attachments`, run
  in a task, the screen serving the phone action). What's picked waits
  above the composer as `[x] name size` (tap to drop it) and goes with the
  next message, which may be just the files; the line says when the
  model will get only a picture's path (it doesn't take pictures).

  On Android the composer has a mic: hold it and talk (`on_press_in` /
  `on_press_out` on a plain box); on release the phone transcribes it offline
  (`MobSpeech` with the `MobWhisper` engine; the mic shows "…" meanwhile) and
  the text lands in the draft (after what was already typed) to edit and send.
  Let go within 300 ms and it cancels with a hint. `[voice:…]` cycles what the agent says
  aloud (`Operator.Core.Settings.voice/0`). The first send asks for the
  notification permission (the background-run notification needs it on
  Android 13+).

  A proposed self-change shows with its diff; on the phone its approve chip
  is `Operator.Core.ApproveButton` (the system prompt: fingerprint or face,
  or the screen lock's PIN, pattern, password or passcode), whose pass
  activates it. With approve all on (`Operator.Core.Dyn.AutoApprove`, set in
  [menu]) a candidate activates as it arrives, through the same
  confirmation and activation, with a notice and `auto` in the status line;
  if that fails the approval bar shows with the reason.

  `operator://` links scanned on the Mac's QR codes (`Operator.Links`)
  come here: a handoff's parts are collected, and the last one switches to
  a new session that opens with the handoff (the model sees it with the
  next prompt); a login link opens `Operator.LoginScanScreen` at the words.
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.ChatScreen.Follow
  alias Operator.ChatScreen.Native
  alias Operator.Core.ApproveButton
  alias Operator.Core.Attachments
  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.AutoApprove
  alias Operator.Core.DynTheme
  alias Operator.Core.Loop
  alias Operator.Core.Models
  alias Operator.Core.Phone
  alias Operator.Core.Session
  alias Operator.Core.Settings
  alias Operator.Core.Term
  alias Operator.Core.Term.Markup
  alias Operator.Core.Term.Stream, as: TermStream
  alias Operator.Core.Usage
  alias Operator.Links
  alias Operator.TermUI, as: UI
  alias Operator.Toggle

  @flush_ms 100
  @stick_ms 60
  @stick_retries 4
  @stick_retry_ms 150
  @attach_stick_ms 300
  @toast_ms 1_500
  @ime_commit_ms 100
  @window 300
  @max_native 200
  @proposal_diff_lines 200
  @list_id "transcript"
  # A shorter hold of the mic is a tap: too short to have said anything.
  @min_hold_ms 300
  # Photos per [attach] › photo library.
  @attach_max 10
  # The transcript lines left showing above the open composer.
  @sliver_lines 2
  # The draft's field: rows in the bar, and in the open composer the rows
  # it draws before it scrolls (on Android it also fills the composer).
  @closed_lines 2
  @composer_lines 12
  @composer_lines_ios 8
  # Opening, the composer slides up over the transcript: its share of the
  # height (a weight against the transcript's 1) per frame, @slide_ms apart,
  # before the transcript settles at its sliver.
  @slide_weights [0.15, 0.5, 1.2, 3.0, 7.0]
  @slide_ms 25

  def mount(params, _session, socket) do
    loop = Map.get(params, :loop) || Operator.Core.current()
    settings_dir = Map.get(params, :settings_dir) || Operator.Paths.data_dir()
    _ = Dyn.subscribe()
    :ok = Phone.register_host(self())
    :ok = DynTheme.subscribe()
    if Process.whereis(Mob.Device), do: Mob.Device.subscribe(:app)
    if Process.whereis(Auth), do: :ok = Auth.subscribe()
    :ok = Usage.subscribe()
    # A link the menu or Diagnostics received: they forward it here.
    with %{link: link} <- params, do: send(self(), {:operator_link, link})
    # Dictation's offline speech model: fetched once, then loaded in the
    # background so the first hold doesn't wait for it.
    if Term.platform() in [:android, :ios], do: MobWhisper.prefetch(notify: self())

    {:ok,
     socket
     |> Mob.Socket.assign(window: @window, draft: "", toast: nil, signed_in: signed_in?())
     |> Mob.Socket.assign(
       composing: false,
       slide: nil,
       field_gen: 0,
       retiring_field: nil,
       pending_send: nil
     )
     |> Mob.Socket.assign(
       settings_dir: settings_dir,
       voice: Settings.voice(settings_dir),
       dictation_base: nil,
       dictation: :idle,
       mic_down_at: nil,
       notifications_asked: false,
       proposal: pending_proposal(),
       auto_approve: AutoApprove.on?(),
       activated: nil,
       phone: %{},
       foreground: true,
       attach_menu: false,
       # The picks being waited for (a ref each); a late one still lands.
       attaching: MapSet.new(),
       attachments: [],
       images?: true
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
          [
            # Sized by its column: iOS's lazy list ignores a height of its own.
            %{
              type: :column,
              props: Map.merge(%{id: "transcript_box", fill_width: true}, list_size(assigns, t)),
              children: [
                %{
                  type: :lazy_list,
                  props: %{id: @list_id, weight: 1, padding: t.padding, background: bg},
                  children: assigns.visible
                }
              ]
            },
            footer(assigns, t)
          ] ++
          if(assigns.composing, do: [], else: approval_bar(assigns, t)) ++
          composer_head(assigns, t) ++
          attach_rows(assigns, t) ++
          [composer(assigns, t)] ++
          composer_spacer(assigns, t) ++
          composer_actions(assigns, t)
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

  # Back from the front (`Operator.ShellScreen` going away): the native list
  # was rebuilt at its top. Like a terminal, it shows the end again.
  def handle_info(:operator_terminal_shown, socket) do
    send(self(), :stick)
    Process.send_after(self(), :stick, @attach_stick_ms)
    {:noreply, Mob.Socket.assign(socket, following: true, last_offset: nil)}
  end

  # Only the toast it was set for: a newer one keeps its full time.
  def handle_info({:clear_toast, text}, %{assigns: %{toast: text}} = socket),
    do: {:noreply, socket |> Mob.Socket.assign(:toast, nil) |> refresh()}

  def handle_info({:clear_toast, _older}, socket), do: {:noreply, socket}

  # ── composer ──

  def handle_info({:change, {:draft, gen}, value}, socket) do
    a = socket.assigns

    if gen in [a.field_gen, a.retiring_field, a.pending_send] do
      retiring = if gen == a.field_gen, do: nil, else: a.retiring_field
      {:noreply, Mob.Socket.assign(socket, draft: value, retiring_field: retiring)}
    else
      {:noreply, socket}
    end
  end

  # Focusing the closed field opens the composer around it. The generation in
  # the event prevents a late native event from a replaced field reopening it.
  def handle_info(
        {:focus, {:draft, gen}},
        %{assigns: %{field_gen: gen, composing: false, pending_send: nil}} = socket
      ) do
    socket = Mob.Socket.assign(socket, :retiring_field, nil)

    if ios?() do
      {:noreply, socket |> Mob.Socket.assign(composing: true, slide: nil) |> restick()}
    else
      Process.send_after(self(), {:composer_slide, 1}, @slide_ms)
      {:noreply, Mob.Socket.assign(socket, composing: true, slide: 0)}
    end
  end

  def handle_info({:focus, {:draft, _gen}}, socket), do: {:noreply, socket}

  # Replacing a focused field commits any active IME composition. Native sends
  # the final change before blur; blur sends immediately, with a timer fallback.
  def handle_info({:blur, {:draft, gen}}, %{assigns: %{pending_send: gen}} = socket),
    do: finish_pending_send(socket, gen)

  def handle_info({:blur, {:draft, gen}}, %{assigns: %{retiring_field: gen}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :retiring_field, nil)}

  def handle_info({:blur, {:draft, _gen}}, socket), do: {:noreply, socket}

  def handle_info({:commit_send, gen}, socket), do: finish_pending_send(socket, gen)

  def handle_info({:retire_field, gen}, %{assigns: %{retiring_field: gen}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :retiring_field, nil)}

  def handle_info({:retire_field, _gen}, socket), do: {:noreply, socket}

  # One chain of frames: a late one from an earlier opening doesn't match.
  def handle_info({:composer_slide, step}, %{assigns: %{composing: true, slide: s}} = socket)
      when step == s + 1 do
    if step < length(@slide_weights) do
      Process.send_after(self(), {:composer_slide, step + 1}, @slide_ms)
      {:noreply, Mob.Socket.assign(socket, :slide, step)}
    else
      {:noreply, socket |> Mob.Socket.assign(:slide, nil) |> restick()}
    end
  end

  # Closed (or sent) before it finished sliding.
  def handle_info({:composer_slide, _step}, socket), do: {:noreply, socket}

  def handle_info({:tap, :hide_composer}, socket), do: {:noreply, retire_composer(socket)}

  def handle_info({:tap, :send}, %{assigns: %{pending_send: pending}} = socket)
      when not is_nil(pending),
      do: {:noreply, socket}

  def handle_info({:tap, :send}, %{assigns: %{composing: true}} = socket),
    do: begin_pending_send(socket)

  def handle_info({:tap, :send}, socket), do: send_draft(socket)

  # A front screen's "use this" (Operator.Core.Terminal): text for the
  # draft, after anything typed, never sent.
  def handle_info({:operator_draft, text}, socket) when is_binary(text) do
    draft =
      case String.trim_trailing(socket.assigns.draft) do
        "" -> text
        typed -> typed <> " " <> text
      end

    {:noreply, Mob.Socket.assign(socket, :draft, draft)}
  end

  def handle_info({:tap, :stop}, socket) do
    Loop.stop(socket.assigns.loop)
    {:noreply, socket}
  end

  def handle_info({:tap, :attach}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :attach_menu, not socket.assigns.attach_menu)}

  def handle_info({:tap, {:attach, source}}, socket) when source in [:photos, :camera, :files],
    do: {:noreply, start_attach(socket, source)}

  def handle_info({:tap, {:unattach, i}}, socket),
    do:
      {:noreply,
       Mob.Socket.assign(socket, :attachments, List.delete_at(socket.assigns.attachments, i))}

  def handle_info({:tap, :stop_attaching}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :attaching, MapSet.new())}

  def handle_info({:attached, ref, result}, socket) do
    socket = Mob.Socket.assign(socket, :attaching, MapSet.delete(socket.assigns.attaching, ref))

    case result do
      {:ok, files} when is_list(files) ->
        {:noreply,
         Mob.Socket.assign(socket,
           attachments: socket.assigns.attachments ++ files,
           images?: Models.images?(socket.assigns.model)
         )}

      {:ok, :cancelled} ->
        {:noreply, socket}

      {:error, text} ->
        {:noreply, toast(socket, text)}
    end
  end

  # ── dictation (the mic's press in/out → MobSpeech, whisper engine) ──

  def handle_info({:press_in, :mic}, socket) do
    {engine, opts} = dictation_engine()
    socket = MobSpeech.listen(socket, [engine: engine] ++ opts)

    {:noreply,
     Mob.Socket.assign(socket,
       dictation: :listening,
       mic_down_at: System.monotonic_time(:millisecond)
     )}
  end

  # Let go too soon to have said anything: cancel, and say how it works.
  def handle_info({:press_out, :mic}, %{assigns: %{mic_down_at: down_at}} = socket)
      when is_integer(down_at) do
    socket = Mob.Socket.assign(socket, :mic_down_at, nil)

    if System.monotonic_time(:millisecond) - down_at < @min_hold_ms do
      socket = socket |> MobSpeech.cancel() |> toast("Hold mic while you talk; let go to stop")
      {:noreply, socket}
    else
      {:noreply, MobSpeech.stop(socket)}
    end
  end

  def handle_info({:press_out, :mic}, socket), do: {:noreply, socket}

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

  # No RECORD_AUDIO: ask the OS, then say what to do once it's allowed.
  def handle_info({:speech, :error, :permission}, socket) do
    Native.impl().request_permission(:microphone)
    {:noreply, toast(socket, "Allow the microphone, then hold mic and talk")}
  end

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

  # A tool's permission (Operator.Core.Phone): the actions waiting on it
  # start, or hear that the user didn't allow it.
  def handle_info({:permission, capability, result}, socket)
      when capability in [:location, :camera, :media, :activity_recognition, :all_files],
      do: {:noreply, permission_answered(socket, capability, result)}

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
      when action in [:camera_photo, :camera_snap, :pick_photos, :pick_file] do
    Phone.reply(
      from,
      ref,
      {:error, "Operator isn't on screen; ask the user to open it, then try again."}
    )

    {:noreply, socket}
  end

  # Tools run in parallel, so several can ask for one capability at once
  # (two file tools in shared storage): they all wait on one request and
  # one answer. Another action of a kind that's still running is refused.
  def handle_info({:phone_request, ref, from, :permission, %{capability: capability}}, socket) do
    key = {:permission, capability}
    live = socket.assigns.phone |> Map.get(key, []) |> Enum.filter(&alive?/1)
    if live == [], do: Native.impl().request_permission(capability)
    {:noreply, put_phone(socket, key, live ++ [{ref, from}])}
  end

  def handle_info({:phone_request, ref, from, action, args}, socket) do
    if alive?(socket.assigns.phone[action]) do
      Phone.reply(from, ref, {:error, "Another #{action} request is still waiting."})
      {:noreply, socket}
    else
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

  def handle_info({:camera, :snapped, %{} = photo}, socket),
    do: {:noreply, phone_done(socket, :camera_snap, {:ok, photo})}

  def handle_info({:camera, :snap_error, reason}, socket),
    do: {:noreply, phone_done(socket, :camera_snap, {:error, snap_error(reason)})}

  def handle_info({:photos, :picked, items}, socket),
    do: {:noreply, phone_done(socket, :pick_photos, {:ok, items})}

  def handle_info({:photos, :cancelled}, socket),
    do: {:noreply, phone_done(socket, :pick_photos, {:ok, :cancelled})}

  def handle_info({:files, :picked, items}, socket),
    do: {:noreply, phone_done(socket, :pick_file, {:ok, items})}

  def handle_info({:files, :cancelled}, socket),
    do: {:noreply, phone_done(socket, :pick_file, {:ok, :cancelled})}

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

  # The approval bar takes its room from the transcript once laid out, after
  # repaint's own stick: a following list sticks again then.
  def handle_info({:operator_dyn, %{type: :candidate, gen: n}}, socket) do
    socket = Mob.Socket.assign(socket, :auto_approve, AutoApprove.on?())

    if socket.assigns.auto_approve,
      do: {:noreply, auto_activate(socket, n)},
      else: {:noreply, show_proposal(socket, n)}
  end

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

  # ── top bar and menu (Operator.MenuScreen) ──

  def handle_info({:tap, :show_earlier}, socket),
    do:
      {:noreply,
       socket |> Mob.Socket.assign(:window, socket.assigns.window + @window) |> refresh()}

  def handle_info({:tap, :menu}, socket) do
    params = socket.assigns |> Map.take([:loop, :model, :path]) |> Map.put(:chat, self())
    {:noreply, Mob.Socket.push_screen(socket, Operator.MenuScreen, params)}
  end

  def handle_info({:operator_menu, :new_session}, socket) do
    socket = detach(socket)
    {:noreply, attach(socket, Operator.Core.new_session())}
  end

  def handle_info({:operator_menu, {:resume, path}}, socket),
    do: handle_info({:open_session, path}, socket)

  def handle_info({:operator_menu, :renderer}, socket), do: {:noreply, rerender(socket)}

  def handle_info({:operator_menu, :auto_approve}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :auto_approve, AutoApprove.on?())}

  def handle_info({:operator_auth, :changed}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:signed_in, signed_in?()) |> refresh()}

  # A model call (from any loop) or a usage page refresh changed the numbers.
  def handle_info({:operator_usage, :changed}, socket), do: {:noreply, load_usage(socket)}

  # A session file brought over from omp (scripts/session.sh push).
  def handle_info({:open_session, path}, socket) do
    case Operator.Core.open_session(path) do
      {:ok, loop} ->
        {:noreply, socket |> detach() |> attach(loop) |> toast("Opened #{Path.basename(path)}")}

      {:error, reason} ->
        {:noreply, toast(socket, "Couldn't open #{Path.basename(path)}: #{inspect(reason)}")}
    end
  end

  # ── operator:// links (Operator.Links) ──

  # Scanned with another app, a link arrives as mob's {:link, ...}
  # (Mob.Link); the menu and Diagnostics forward theirs through `mount/3`.
  # The scan happens with that app in front, so the toasts last.
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

      {:cluster, invite} ->
        {:noreply, Mob.Socket.push_screen(socket, Operator.ClusterScreen, %{invite: invite})}

      {:error, text} ->
        {:noreply, lasting_toast(socket, text)}
    end
  end

  # `[frontend]` in the top bar: to the front.
  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

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
        path: snap.path,
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
    socket = load_usage(socket)
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
  # Each message starts with its time (`Term.stamped_rows/4`).
  defp message(entry, key, owner),
    do: %{key: key, entry: entry, rows: Term.stamped_rows(entry, key, owner)}

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

  defp on_event(%{type: :model_change, model: model}, socket) do
    socket = Mob.Socket.assign(socket, :model, model)

    if socket.assigns.attachments == [],
      do: socket,
      else: Mob.Socket.assign(socket, :images?, Models.images?(model))
  end

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

    sign_in =
      if a.signed_in,
        do: [],
        else: [
          Term.notice_row("Not signed in to a model: [menu] › accounts to sign in.", "sign-in")
        ]

    proposal =
      if a.proposal, do: Term.entry_rows(a.proposal.entry, a.proposal.key, owner), else: []

    Mob.Socket.assign(socket, :visible, earlier ++ rows ++ proposal ++ sign_in ++ toast)
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

  defp begin_pending_send(socket) do
    gen = socket.assigns.field_gen
    Process.send_after(self(), {:commit_send, gen}, @ime_commit_ms)

    {:noreply,
     socket
     |> Mob.Socket.assign(
       composing: false,
       slide: nil,
       field_gen: gen + 1,
       retiring_field: nil,
       pending_send: gen,
       attach_menu: false
     )
     |> restick()}
  end

  defp finish_pending_send(%{assigns: %{pending_send: gen}} = socket, gen) do
    socket = Mob.Socket.assign(socket, :pending_send, nil)

    cond do
      String.trim(socket.assigns.draft) == "" and socket.assigns.attachments == [] ->
        {:noreply, socket |> Mob.Socket.assign(composing: true, slide: nil) |> restick()}

      MapSet.size(socket.assigns.attaching) > 0 ->
        {:noreply,
         socket
         |> Mob.Socket.assign(composing: true, slide: nil)
         |> toast("Still attaching: send again in a moment")}

      true ->
        send_draft(socket)
    end
  end

  defp finish_pending_send(socket, _gen), do: {:noreply, socket}

  # Hiding keeps the draft, including the native field's final composition.
  # Accept that retiring field only until its blur (or this short fallback).
  defp retire_composer(%{assigns: %{composing: true}} = socket) do
    gen = socket.assigns.field_gen
    Process.send_after(self(), {:retire_field, gen}, @ime_commit_ms)

    socket
    |> Mob.Socket.assign(
      composing: false,
      slide: nil,
      field_gen: gen + 1,
      retiring_field: gen,
      attach_menu: false
    )
    |> restick()
  end

  defp retire_composer(socket), do: socket

  defp send_draft(socket) do
    text = String.trim(socket.assigns.draft)
    files = socket.assigns.attachments
    sent = [draft: "", attachments: [], following: true]

    cond do
      text == "" and files == [] ->
        {:noreply, socket}

      # A pick is still being kept and scaled: don't send without its files.
      MapSet.size(socket.assigns.attaching) > 0 ->
        {:noreply, toast(socket, "Still attaching: send again in a moment")}

      socket.assigns.status == :running ->
        :ok = Loop.steer(socket.assigns.loop, text, files)
        {:noreply, socket |> Mob.Socket.assign(sent) |> close_composer()}

      true ->
        case Loop.prompt(socket.assigns.loop, text, files) do
          :ok -> :ok
          {:error, :running} -> Loop.steer(socket.assigns.loop, text, files)
        end

        {:noreply, socket |> ask_notifications() |> Mob.Socket.assign(sent) |> close_composer()}
    end
  end

  # Back to the full transcript after sending. The field generation was
  # already advanced to flush the IME; any late event from it is ignored.
  defp close_composer(%{assigns: %{composing: true}} = socket) do
    socket
    |> Mob.Socket.assign(
      composing: false,
      slide: nil,
      field_gen: socket.assigns.field_gen + 1,
      retiring_field: nil,
      pending_send: nil,
      attach_menu: false
    )
    |> restick()
  end

  defp close_composer(socket) do
    Mob.Socket.assign(socket,
      field_gen: socket.assigns.field_gen + 1,
      retiring_field: nil,
      pending_send: nil
    )
  end

  # The transcript changed height: a following list goes back to its end.
  defp restick(socket) do
    if socket.assigns.following, do: Process.send_after(self(), :stick, @stick_ms)
    socket
  end

  # The pick runs in a task: the pickers and the camera are phone actions
  # this screen serves (`{:phone_request, ...}`), the same ones the tools
  # ask for, through the same `Attachments` functions.
  defp start_attach(socket, source) do
    screen = self()
    ref = make_ref()
    ctx = %{phone_host: screen, data_dir: socket.assigns.settings_dir}

    Task.start(fn ->
      result =
        try do
          pick(source, ctx)
        rescue
          e -> {:error, "Couldn't attach it: " <> Exception.message(e)}
        catch
          kind, reason ->
            {:error, "Couldn't attach it: " <> Exception.format_banner(kind, reason)}
        end

      send(screen, {:attached, ref, result})
    end)

    Mob.Socket.assign(socket,
      attach_menu: false,
      attaching: MapSet.put(socket.assigns.attaching, ref)
    )
  end

  defp pick(:photos, ctx), do: Attachments.pick_photos(@attach_max, ctx)
  defp pick(:camera, ctx), do: Attachments.take_photo(ctx)
  defp pick(:files, ctx), do: Attachments.pick_files([:any], ctx)

  # News that arrives while another app is in front (a QR app during a
  # handoff) stays up long enough to be seen on return.
  defp lasting_toast(socket, text) do
    Process.send_after(self(), {:clear_toast, text}, 20_000)
    socket |> Mob.Socket.assign(:toast, text) |> repaint()
  end

  defp signed_in?, do: Enum.any?(Auth.status(), fn {_provider, st} -> st.signed_in end)

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

  defp dictation_error(:audio), do: "The microphone stopped (headset change?): try again"
  defp dictation_error(reason), do: "Dictation failed (#{inspect(reason)})"

  defp model_error(:network),
    do: "Couldn't download the speech model (60 MB): dictation needs it once"

  defp model_error(reason), do: "The speech model didn't load (#{inspect(reason)})"

  defp voice_hint(:off), do: "silent"
  defp voice_hint(:important), do: "speaks when a run ends"
  defp voice_hint(:everything), do: "speaks every reply"

  # Location and the camera ask for their permission first (the answer
  # starts the action, `{:permission, ...}` above); a notification is
  # scheduled at once and answered with its id; the pickers open.
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

  # Each action waits under its own key as `{ref, from, args, started}`;
  # `:permission` requests wait as a list of `{ref, from}` under
  # `{:permission, capability}` (handle_info above). An action whose picker
  # or permission request can't even start (e.g. its NIF isn't loaded) is
  # answered at once instead of waiting out the tool's timeout.
  defp start_phone(socket, ref, from, action, args) do
    started = action in [:pick_photos, :pick_file]

    result =
      if started,
        do: Native.impl().phone(action, args),
        else: Native.impl().request_permission(needs(action))

    case result do
      :ok ->
        {:noreply, put_phone(socket, action, {ref, from, args, started})}

      {:error, reason} ->
        Phone.reply(from, ref, {:error, "Couldn't start #{action}: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  defp put_phone(socket, key, entry),
    do: Mob.Socket.assign(socket, :phone, Map.put(socket.assigns.phone, key, entry))

  defp alive?({_ref, from}), do: Process.alive?(from)
  defp alive?({_ref, from, _args, _started}), do: Process.alive?(from)
  defp alive?(nil), do: false

  defp needs(:location), do: :location
  defp needs(action) when action in [:camera_photo, :camera_snap], do: :camera
  defp needs(_action), do: nil

  # Every `:permission` waiter hears the answer. An action waiting on it
  # starts once (a second grant, from another action's request, doesn't
  # start it again), and only if its tool is still waiting: one that gave
  # up is forgotten, so a late Allow takes no photo nobody asked for.
  defp permission_answered(socket, capability, result) do
    {waiters, phone} = Map.pop(socket.assigns.phone, {:permission, capability}, [])
    answer = if result == :granted, do: {:ok, :granted}, else: {:error, denied(capability)}
    Enum.each(waiters, fn {ref, from} -> Phone.reply(from, ref, answer) end)

    phone =
      Enum.reduce(phone, phone, fn
        {action, {ref, from, args, false}}, acc ->
          cond do
            needs(action) != capability ->
              acc

            not Process.alive?(from) ->
              Map.delete(acc, action)

            result == :granted ->
              start_granted(acc, action, ref, from, args)

            true ->
              Phone.reply(from, ref, {:error, denied(capability)})
              Map.delete(acc, action)
          end

        _started_or_waiters, acc ->
          acc
      end)

    Mob.Socket.assign(socket, :phone, phone)
  end

  defp start_granted(phone, action, ref, from, args) do
    case Native.impl().phone(action, args) do
      :ok ->
        Map.put(phone, action, {ref, from, args, true})

      {:error, reason} ->
        Phone.reply(from, ref, {:error, "Couldn't start #{action}: #{inspect(reason)}"})
        Map.delete(phone, action)
    end
  end

  @doc false
  # What the model hears when a permission isn't granted: the dialog may
  # have been dismissed (or never seen), so it can ask the user and retry.
  @spec denied(atom()) :: String.t()
  def denied(:all_files),
    do:
      "Operator has no access to the phone's shared storage. Ask the user to keep Operator " <>
        "open and allow it when asked: on Android 11 and later that's the All files access " <>
        "page in Settings (switch on \"Allow access to manage all files\" for Operator, then " <>
        "come back to the app); on older Android it's a storage dialog (tap Allow). Then call " <>
        "the tool again."

  def denied(capability) do
    "The user didn't allow #{permission_name(capability)} (they refused, or the prompt was " <>
      "dismissed or never seen). Ask them to tap Allow when it shows and call the tool again; " <>
      "if no prompt appears, they need to allow it in Settings › Apps › Operator › Permissions."
  end

  defp permission_name(:camera), do: "camera access"
  defp permission_name(:location), do: "location access"
  defp permission_name(:media), do: "access to their photos"
  defp permission_name(:activity_recognition), do: "physical activity (motion) access"
  defp permission_name(other), do: "#{other} access"

  defp snap_error(:no_camera), do: "This phone has no camera on that side (or it's a simulator)."
  defp snap_error(:permission), do: denied(:camera)

  defp snap_error(:busy),
    do: "The camera is busy (another app or capture is using it); try again."

  defp snap_error(:background),
    do:
      "Operator isn't on screen, and Android won't open the camera for it; ask the user to open it."

  defp snap_error(reason), do: "The camera failed: #{inspect(reason)}"

  defp phone_done(socket, action, result) do
    case Map.pop(socket.assigns.phone, action) do
      {{ref, from, _args, _started}, rest} ->
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
            "Approve below (fingerprint, face, or the screen lock's PIN, pattern, password " <>
            "or passcode), or deny it."

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

  defp show_proposal(socket, n) do
    socket = socket |> Mob.Socket.assign(:proposal, proposal(n)) |> repaint()
    if socket.assigns.following, do: Process.send_after(self(), :stick, @attach_stick_ms)
    socket
  end

  # Approve all (`AutoApprove`): the same confirmation and activation as the
  # approve chip's pass; a failure shows the approval bar with the reason.
  defp auto_activate(socket, n) do
    subject = {:activate, n}

    with {:confirm, :ok} <- {:confirm, Native.impl().confirm_approval(subject)},
         {:ok, socket} <- do_activate(socket, n) do
      toast(
        socket,
        "Generation #{n} activated automatically (approve all is on; [menu] to turn off)"
      )
    else
      {:confirm, {:error, reason}} -> fallback(socket, n, inspect(reason))
      {:error, why} -> fallback(socket, n, why)
    end
  end

  defp fallback(socket, n, why) do
    socket
    |> show_proposal(n)
    |> not_activated(n, "approve all couldn't activate it: #{why}")
  end

  defp activate(socket, n) do
    case do_activate(socket, n) do
      {:ok, socket} ->
        toast(
          socket,
          "Generation #{n} is live, on probation: it reverts by itself if it keeps crashing"
        )

      {:error, why} ->
        not_activated(socket, n, why)
    end
  end

  defp do_activate(socket, n) do
    with {:ok, token} <- Dyn.request_approval({:activate, n}),
         {:ok, _gen} <- Dyn.activate(n, token) do
      {:ok, Mob.Socket.assign(socket, proposal: nil, activated: n)}
    else
      {:error, :approval_required} ->
        {:error, "it needs approving through the phone's screen-lock prompt"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
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
    # Approve all stays in sight while it's on.
    auto = if a.auto_approve, do: ["auto"], else: []

    fields =
      ["#{a.status}#{queued}"] ++ auto ++ limits(a) ++ ["$#{cost}", "#{tokens} tok", model]

    line = Enum.join(fields, " · ")

    UI.top_bar(t, [
      UI.link("menu", :menu, t),
      UI.text(line, t, "dim", weight: 1, max_lines: 1, text_size: t.text_size - 2)
    ])
  end

  # The model's subscription windows (`Operator.Core.Usage.status_text/3`).
  defp limits(a) do
    with {:ok, provider} <- Auth.provider_for_model(a.model),
         text when is_binary(text) <- Usage.status_text(a.usage, provider) do
      [text]
    else
      _ -> []
    end
  end

  # The numbers as `Operator.Core.Usage` has them now.
  defp load_usage(socket),
    do: Mob.Socket.assign(socket, :usage, Usage.load(socket.assigns.settings_dir))

  defp footer(a, t) do
    detail = a.detail || if(a.status == :running, do: "working…", else: "")

    UI.bar_row(t, [
      UI.text(detail, t, "dim",
        weight: 1,
        max_lines: 1,
        font: :term_italic,
        text_size: t.text_size - 2
      ),
      footer_link("voice:#{a.voice}", :cycle_voice, t),
      footer_link("copy last reply", :copy_last, t)
    ])
  end

  defp footer_link(label, tag, t),
    do: UI.link(label, tag, t, text_size: t.text_size - 2, padding: 0)

  # The transcript fills the screen; while composing it shrinks to its last
  # lines (still following), a live sliver above the composer.
  defp list_size(%{composing: true, slide: nil}, t),
    do: %{height: round(@sliver_lines * (t.text_size * t.line_height + 3) + 2 * t.padding)}

  defp list_size(_a, _t), do: %{weight: 1}

  # One row, the draft's field first, in both states: the field keeps its
  # id and place (root › "composer" › its id), so the focus that opened the
  # composer, and the keyboard, carry over into it. Closing renders a new
  # field (`field_gen`), which takes the focus and the keyboard away.
  defp composer(a, t) do
    placeholder = if a.status == :running, do: "› steer the agent…", else: "› ask Operator…"
    tag = {:draft, a.field_gen}

    field_props = [
      id: "draft-#{a.field_gen}",
      on_focus: {self(), tag},
      on_blur: {self(), tag},
      disabled: not is_nil(a.pending_send)
    ]

    if a.composing do
      {flex, lines} =
        if ios?(),
          do: {%{}, [lines: @composer_lines_ios]},
          else:
            {%{weight: if(a.slide, do: Enum.at(@slide_weights, a.slide), else: 1)},
             [lines: @composer_lines, fill_height: true]}

      %{
        type: :row,
        props:
          Map.merge(
            %{id: "composer", fill_width: true, padding: 6, background: Term.color(t, "bar")},
            flex
          ),
        children: [
          UI.field(
            a.draft,
            placeholder,
            tag,
            t,
            field_props ++ [weight: 1, underline: false] ++ lines
          )
        ]
      }
    else
      t
      |> UI.bar_row([
        UI.field(
          a.draft,
          placeholder,
          tag,
          t,
          field_props ++ [weight: 1, lines: @closed_lines]
        )
        | send_controls(a, t)
      ])
      |> put_in([:props, :id], "composer")
    end
  end

  defp send_controls(a, t) do
    running = a.status == :running
    stop = if running, do: [UI.chip("Stop", :stop, t, "error")], else: []

    [UI.link("attach", :attach, t, padding: 4)] ++
      mic(a, t) ++ [UI.chip(if(running, do: "Steer", else: "Send"), :send, t, "user")] ++ stop
  end

  # The composer's title: what it's for, and [hide] (the draft stays).
  defp composer_head(%{composing: true} = a, t) do
    title = if a.status == :running, do: "── steer ", else: "── compose "

    [
      UI.bar_row(t, [
        UI.text(title <> String.duplicate("─", 20), t, "dim", weight: 1, max_lines: 1),
        UI.link("hide", :hide_composer, t, padding: 4)
      ])
    ]
  end

  defp composer_head(_a, _t), do: []

  defp composer_actions(%{composing: true} = a, t),
    do: [UI.bar_row(t, [UI.text("", t, "dim", weight: 1) | send_controls(a, t)])]

  defp composer_actions(_a, _t), do: []

  # On iOS a node that gains or loses a weight is a new view to SwiftUI, and
  # its subtree with it: the field would lose the focus that opened the
  # composer. There the composer row never flexes; a spacer below it takes
  # the slack, the field has fewer rows (small iPhones), and it doesn't slide.
  defp ios?, do: Term.platform() == :ios

  defp composer_spacer(%{composing: true}, t) do
    if ios?(),
      do: [
        %{
          type: :column,
          props: %{
            id: "composer_spacer",
            weight: 1,
            fill_width: true,
            background: Term.color(t, "bar")
          },
          children: []
        }
      ],
      else: []
  end

  defp composer_spacer(_a, _t), do: []

  # Above the composer: the [attach] list while it's open, a pick in
  # progress, and what goes with the next message (tap a line to drop it).
  defp attach_rows(a, t) do
    menu =
      if a.attach_menu,
        do: [
          UI.bar_row(t, [
            UI.text("attach", t, "dim", text_size: t.text_size - 1),
            UI.link("photo library", {:attach, :photos}, t, padding: 4),
            UI.link("take photo", {:attach, :camera}, t, padding: 4),
            UI.link("file", {:attach, :files}, t, padding: 4)
          ])
        ],
        else: []

    # Tap to stop waiting (a picker that never answers); a late pick still lands.
    pending =
      if MapSet.size(a.attaching) > 0,
        do: [
          UI.text("attaching… (tap to stop waiting)", t, "dim",
            font: :term_italic,
            on_tap: {self(), :stop_attaching}
          )
        ],
        else: []

    chips =
      for {file, i} <- Enum.with_index(a.attachments) do
        UI.text("[x] " <> Attachments.label(file, a.images?), t, "user",
          on_tap: {self(), {:unattach, i}},
          max_lines: 1,
          accessibility_role: "button",
          accessibility_label: "Remove #{file.name}"
        )
      end

    case chips ++ pending do
      [] ->
        menu

      lines ->
        menu ++
          [
            %{
              type: :column,
              props: %{fill_width: true, padding: 6, gap: 4, background: Term.color(t, "bar")},
              children: lines
            }
          ]
    end
  end

  # Hold to talk: a plain box observing the finger (on_press_in / on_press_out,
  # always paired). "● rec" from the touch, "…" while Whisper transcribes (it
  # has no partial results). On the phone only: Whisper's capture is native
  # (Android AudioRecord, iOS AudioQueue).
  defp mic(a, t) do
    if Term.platform() in [:android, :ios] do
      label =
        cond do
          a.mic_down_at != nil or a.dictation == :listening -> "● rec"
          a.dictation == :processing -> "…"
          true -> "mic"
        end

      [
        %{
          type: :box,
          props: %{
            id: "mic",
            on_press_in: {self(), :mic},
            on_press_out: {self(), :mic},
            accessibility_label: "Hold to dictate",
            accessibility_role: "button",
            background: Term.color(t, "code_bg"),
            padding: 10,
            # A box fills the row by default; the mic is as wide as its label.
            fill_width: false
          },
          children: [
            UI.text(label, t, if(label == "mic", do: "fg", else: "error"),
              text_size: t.text_size - 1
            )
          ]
        }
      ]
    else
      []
    end
  end

  defp approval_bar(%{proposal: %{gen: n}}, t) do
    [
      UI.bar_row(t, [
        UI.text("proposal G#{n}", t, "accent",
          weight: 1,
          max_lines: 1,
          text_size: t.text_size - 1
        ),
        # The preferred action goes right-most.
        UI.chip("deny", :deny_proposal, t, "error"),
        approve_chip(n, t)
      ])
    ]
  end

  defp approval_bar(_a, _t), do: []

  # The system screen-lock prompt (a native view on the phone).
  defp approve_chip(n, t) do
    if Term.platform() in [:android, :ios] do
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
      UI.chip("approve", :approve_proposal, t, "user")
    end
  end
end
