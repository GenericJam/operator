defmodule Operator.MenuScreen do
  @moduledoc """
  The terminal's settings menu, opened by `[menu]` in the chat's top bar
  (`Operator.ChatScreen`), drawn like the terminal (`Operator.TermUI`).
  Each page is this screen pushed with `%{page: page}`; `[back]` (or the
  system back) pops one page, so the last one returns to the chat.

    * `:main`: every setting at a glance, each line opening its page or
      acting at once: the provider sign-ins, the model, a new session,
      resuming a past one, the renderer (`md:native` / `md:term`,
      `Operator.Core.Term.put_renderer/1`), the subscription usage
      (`Operator.UsageScreen`), the local TLS cluster
      (`Operator.ClusterScreen`), the component library and
      `Operator.DiagnosticsScreen`. The library is a front screen
      (`Operator.Dyn.Showcase.GalleryScreen`, from the Dyn seed): the menu
      opens it in the front, over the front's own screens
      (`Operator.Core.Front.open/3` with `push: true`). Approvals: ask each
      time, or approve all (`Operator.Core.Dyn.AutoApprove`): turning it on
      takes the screen-lock prompt (`Operator.Core.ApproveButton`), off is
      one tap. Under `yours`, the rows the agent added for its own front
      screens (a plugin's screen, say): see "Rows the agent adds" below.
    * `:accounts`: per provider, sign in in the browser (`Operator.Auth.Login`,
      with a field for the `code#state` Anthropic's page shows when it doesn't
      redirect back) or sign out (`Operator.Auth.delete/1`, after a confirm),
      and scanning a login QR made on the Mac (`Operator.LoginScanScreen`).
    * `:model`: the models the signed-in providers offer
      (`Operator.Core.Models`), the current one marked, and a custom spec.
    * `:sessions`: the saved sessions (`Operator.Core.Session.list/1`), newest
      first, the shown one marked.

  Params: `:chat` (the chat screen's pid, told about a new or resumed session
  and a renderer change with `{:operator_menu, action}`), `:loop`, `:model`
  and `:path` (the shown session's loop, model and file: the model is set on
  the loop), `:page` (default `:main`), `:sessions_dir` (default
  `Operator.Core.Session.dir/0`). The accounts page takes over a sign-in
  still in progress (`Operator.Auth.Login.pending/0`).

  **Rows the agent adds.** The agent writes `Operator.Dyn.Menu` (Dyn
  code, see `Operator.Core.Dyn.agent_guide/0`) with `items/0` returning
  `[%{label: "...", detail: "...", screen: "Name.Of.FrontScreen"}]`; each
  row opens its front screen like `components` opens the library. It is
  read at mount and again whenever another generation runs (the main page
  subscribes to `Operator.Core.Dyn`), in a process of its own with a time
  and heap limit, so a raise, a hang, a bad return or a missing module
  costs the section, never the menu: the valid rows show (at most
  20), what was wrong shows (and is logged) below them, and a row whose
  screen isn't in this generation is dimmed and says so when tapped.
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.Auth.Login
  alias Operator.ChatScreen.Native
  alias Operator.Core.ApproveButton
  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.AutoApprove
  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Front
  alias Operator.Core.Loop
  alias Operator.Core.Models
  alias Operator.Core.Session
  alias Operator.Core.Term
  alias Operator.TermUI, as: UI
  alias Operator.Toggle

  require Logger

  @pages [:main, :accounts, :model, :sessions]
  @max_sessions 50
  @library "Showcase.GalleryScreen"
  # The agent's rows (Operator.Dyn.Menu.items/0): at most this many, read
  # within this time and heap (in words), with labels cut to these lengths.
  @max_yours 20
  @yours_timeout_ms 1_000
  @yours_heap_words 2_000_000
  @label_max 48
  @detail_max 60
  # Dyn events after which another generation (or none) runs.
  @generation_events [:activated, :reverted, :loaded, :safe_mode, :load_failed]

  def mount(params, _session, socket) do
    page = Map.get(params, :page, :main)
    if page in [:main, :accounts] and Process.whereis(Auth), do: :ok = Auth.subscribe()
    if page == :main, do: subscribe_dyn()
    dir = Map.get_lazy(params, :sessions_dir, &Session.dir/0)

    {:ok,
     Mob.Socket.assign(socket,
       page: page,
       chat: params.chat,
       loop: params.loop,
       sessions_dir: dir,
       model: params.model,
       path: params.path,
       auth: Auth.status(),
       sessions: if(page == :sessions, do: Enum.take(Session.list(dir), @max_sessions), else: []),
       note: nil,
       pending: if(page == :accounts and Process.whereis(Login), do: Login.pending()),
       code: "",
       confirm: nil,
       model_draft: "",
       auto_approve: page == :main and AutoApprove.on?(),
       yours: if(page == :main, do: yours(), else: {[], nil})
     )}
  end

  def render(assigns) do
    t = Term.theme()
    {title, rows} = page(assigns.page, assigns, t)
    note = if assigns.note, do: [UI.text(assigns.note, t, "notice", font: :term_italic)], else: []
    UI.page(t, title, rows ++ note)
  end

  # ── navigation ──

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

  def handle_info({:tap, {:open, page}}, socket) when page in @pages do
    params =
      socket.assigns
      |> Map.take([:chat, :loop, :model, :path, :sessions_dir])
      |> Map.put(:page, page)

    {:noreply, Mob.Socket.push_screen(socket, __MODULE__, params)}
  end

  def handle_info({:tap, :diagnostics}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.DiagnosticsScreen)}

  def handle_info({:tap, :usage}, socket) do
    params = Map.take(socket.assigns, [:model, :path])
    {:noreply, Mob.Socket.push_screen(socket, Operator.UsageScreen, params)}
  end

  def handle_info({:tap, :cluster}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.ClusterScreen)}

  def handle_info({:tap, :scan_qr}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Operator.LoginScanScreen)}

  # A link scanned with another app while the menu shows: the chat handles it.
  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen, %{link: link})}

  # ── session and display ──

  def handle_info({:tap, :new_session}, socket), do: {:noreply, to_chat(socket, :new_session)}

  def handle_info({:tap, {:resume, path}}, %{assigns: %{path: path}} = socket),
    do: {:noreply, Mob.Socket.pop_to(socket, Operator.ChatScreen)}

  def handle_info({:tap, {:resume, path}}, socket),
    do: {:noreply, to_chat(socket, {:resume, path})}

  def handle_info({:tap, :toggle_renderer}, socket) do
    Term.put_renderer(if Term.renderer() == :native, do: :term, else: :native)
    send(socket.assigns.chat, {:operator_menu, :renderer})
    {:noreply, socket}
  end

  # The component library is a front screen (the terminal never runs Dyn
  # code), so it opens in the front, over the front's own screens.
  def handle_info({:tap, :components}, socket) do
    case Front.open(@library, push: true) do
      {:ok, _} -> {:noreply, Toggle.to_front(socket)}
      {:error, _} -> {:noreply, note(socket, library_missing())}
    end
  end

  # A row the agent added (Operator.Dyn.Menu): its front screen, the same way.
  def handle_info({:tap, {:yours, screen}}, socket) do
    case open_front(screen) do
      {:ok, _} -> {:noreply, Toggle.to_front(socket)}
      {:error, reason} -> {:noreply, note(socket, "Couldn't open #{screen}: #{why(reason)}.")}
    end
  end

  # Another generation runs: its menu module may add, change or drop rows.
  def handle_info({:operator_dyn, %{type: type}}, %{assigns: %{page: :main}} = socket)
      when type in @generation_events,
      do: {:noreply, Mob.Socket.assign(socket, :yours, yours())}

  # ── approvals (Operator.Core.Dyn.AutoApprove) ──

  # On takes the screen lock: the approve chip's pass, confirmed like an activation.
  def handle_info({:approval, "approved", %{"subject" => {:auto_approve, :on} = subject}}, socket) do
    result =
      with :ok <- Native.impl().confirm_approval(subject), do: AutoApprove.enable()

    {:noreply, set_auto_approve(socket, result)}
  end

  def handle_info({:approval, event, payload}, socket) when event in ["failed", "unavailable"],
    do: {:noreply, note(socket, "Approve all stays off: " <> ApproveButton.why(event, payload))}

  def handle_info({:approval, _event, _payload}, socket), do: {:noreply, socket}

  # Off the phone there's no prompt: only an approval needing no confirmation grants it.
  def handle_info({:tap, :auto_approve_on}, socket),
    do: {:noreply, set_auto_approve(socket, AutoApprove.enable())}

  def handle_info({:tap, :auto_approve_off}, socket),
    do: {:noreply, set_auto_approve(socket, AutoApprove.disable())}

  # ── model ──

  def handle_info({:tap, {:pick_model, spec}}, socket), do: {:noreply, set_model(socket, spec)}

  def handle_info({:change, :model_draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :model_draft, value)}

  def handle_info({:tap, :save_model}, socket) do
    case String.trim(socket.assigns.model_draft) do
      "" ->
        {:noreply, note(socket, "Type a model first, e.g. anthropic:claude-sonnet-4-5")}

      model ->
        model = if String.contains?(model, ":"), do: model, else: Session.from_pi_model(model)
        {:noreply, set_model(socket, model)}
    end
  end

  # ── accounts ──

  def handle_info({:tap, {:sign_in, provider}}, socket) do
    case Login.begin(provider) do
      {:ok, url} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(pending: provider, code: "", confirm: nil)
         |> note("Opening #{URI.parse(url).host}: sign in there, then come back to Operator.")}

      {:error, reason} ->
        {:noreply, note(socket, "Couldn't start the sign-in: #{inspect(reason)}")}
    end
  end

  def handle_info({:change, :code, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :code, value)}

  # What Anthropic's page shows when it doesn't redirect back (`code#state`).
  def handle_info({:tap, :paste_code}, %{assigns: %{pending: provider}} = socket)
      when provider != nil do
    case Login.paste(provider, socket.assigns.code) do
      :ok -> {:noreply, note(socket, "Code received: finishing the sign-in…")}
      {:error, reason} -> {:noreply, note(socket, paste_error(reason))}
    end
  end

  def handle_info({:tap, :paste_code}, socket), do: {:noreply, socket}

  def handle_info({:submit, :code}, socket), do: handle_info({:tap, :paste_code}, socket)

  def handle_info({:operator_login, provider, :ok}, socket) do
    who =
      case Auth.get(provider) do
        {:ok, %{"email" => email}} when is_binary(email) -> " as #{email}"
        _ -> ""
      end

    {:noreply,
     socket
     |> Mob.Socket.assign(pending: nil, code: "", auth: Auth.status())
     |> note("Signed in to #{Auth.label(provider)}#{who}.")}
  end

  def handle_info({:operator_login, provider, {:error, message}}, socket),
    do: {:noreply, note(socket, "Sign-in to #{Auth.label(provider)} failed: #{message}")}

  def handle_info({:tap, {:sign_out, provider}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, confirm: provider, note: nil)}

  def handle_info({:tap, :cancel_sign_out}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :confirm, nil)}

  def handle_info({:tap, {:confirm_sign_out, provider}}, socket) do
    socket = Mob.Socket.assign(socket, :confirm, nil)

    case Auth.delete(provider) do
      :ok ->
        {:noreply,
         socket
         |> Mob.Socket.assign(:auth, Auth.status())
         |> note("Signed out of #{Auth.label(provider)}.")}

      {:error, reason} ->
        {:noreply,
         note(
           socket,
           "Couldn't sign out of #{Auth.label(provider)} (#{Auth.describe_error(reason)}): " <>
             "it is still signed in."
         )}
    end
  end

  def handle_info({:operator_auth, :changed}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :auth, Auth.status())}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── actions ──

  # The chat does it (it shows the session) once it's back on screen.
  defp to_chat(socket, action) do
    send(socket.assigns.chat, {:operator_menu, action})
    Mob.Socket.pop_to(socket, Operator.ChatScreen)
  end

  # The chat may have moved to another session (or its loop died) since the
  # menu opened: say so rather than crash the page.
  defp set_model(socket, spec) do
    case Loop.set_model(socket.assigns.loop, spec) do
      :ok -> Mob.Socket.pop_to(socket, Operator.ChatScreen)
      {:error, :running} -> note(socket, "Can't change the model while the agent runs.")
    end
  catch
    :exit, _ ->
      note(socket, "That session isn't running any more: start a new session or resume one.")
  end

  defp note(socket, text), do: Mob.Socket.assign(socket, :note, text)

  defp set_auto_approve(socket, result) do
    send(socket.assigns.chat, {:operator_menu, :auto_approve})
    socket = Mob.Socket.assign(socket, :auto_approve, AutoApprove.on?())

    case result do
      :ok ->
        note(socket, nil)

      {:error, :approval_required} ->
        note(socket, "Approve all stays off: it needs the phone's screen-lock prompt.")

      {:error, reason} ->
        note(socket, "Couldn't change approvals: #{inspect(reason)}")
    end
  end

  defp library_missing do
    if Seed.running?(),
      do: "The front is still being prepared (about half a minute); try again shortly.",
      else:
        "The current front has no component library (#{@library}). Diagnostics › Rescue " <>
          "can go back to the default front's generation, or ask the agent to restore it."
  end

  defp open_front(screen) do
    Front.open(screen, push: true)
  catch
    :exit, _ -> {:error, :no_front}
  end

  defp why(:unknown_screen), do: "no front screen has that name in this generation"
  defp why({:ambiguous, names}), do: "it could be #{Enum.join(names, " or ")}"
  defp why(:no_front), do: "the front isn't running"
  defp why(other), do: inspect(other)

  defp subscribe_dyn do
    Dyn.subscribe()
  catch
    # The Keeper busy or restarting: the rows still come from this mount.
    :exit, _ -> :ok
  end

  # ── the agent's rows (Operator.Dyn.Menu) ──

  # `{rows, problem}`: the valid rows of the current generation's
  # `Operator.Dyn.Menu.items/0`, each marked with whether its screen is in
  # that generation, and what was wrong with the rest (or nil).
  defp yours do
    case Dyn.lookup({:module, "Menu"}) do
      {:ok, mod} ->
        {rows, problem} = read_items(mod)
        if problem, do: Logger.warning("[menu] Operator.Dyn.Menu: #{problem}")
        screens = Enum.map(Dyn.screens(), &elem(&1, 0))
        {Enum.map(rows, &Map.put(&1, :found, screen?(&1.screen, screens))), problem}

      :error ->
        {[], nil}
    end
  end

  # The agent's code runs in a process of its own, with a time and heap
  # limit, and checks its own result there: only the checked rows (small
  # strings) come back to the menu's process.
  defp read_items(mod) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @yours_heap_words, kill: true, error_logger: false})
        send(parent, {tag, checked_items(mod)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {[], "items/0 died (#{short(inspect(reason))})"}
    after
      @yours_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {[], "items/0 took over #{@yours_timeout_ms} ms"}
    end
  end

  defp checked_items(mod) do
    case mod.items() do
      items when is_list(items) -> check_items(items)
      other -> {[], "items/0 returned #{short(inspect(other))}, not a list"}
    end
  rescue
    e -> {[], "items/0 raised: #{short(Exception.message(e))}"}
  catch
    kind, reason -> {[], "items/0 failed: #{short(inspect({kind, reason}))}"}
  end

  defp check_items(items) do
    {rows, bad} =
      items
      |> Enum.take(@max_yours)
      |> Enum.map(&check_item/1)
      |> Enum.split_with(&is_map/1)

    over = length(items) - @max_yours

    problems =
      [
        bad != [] &&
          "#{length(bad)} skipped: a row is %{label: string, screen: string, detail: string}",
        over > 0 && "#{over} more not shown (at most #{@max_yours})"
      ]
      |> Enum.filter(&is_binary/1)

    {rows, if(problems == [], do: nil, else: Enum.join(problems, "; "))}
  end

  defp check_item(%{label: label, screen: screen} = item) do
    detail = Map.get(item, :detail, "")

    if Enum.all?([label, screen, detail], &(is_binary(&1) and String.valid?(&1))) and
         String.trim(label) != "" and String.trim(screen) != "" do
      %{
        label: String.slice(label, 0, @label_max),
        detail: String.slice(detail, 0, @detail_max),
        screen: String.trim(screen)
      }
    else
      :bad
    end
  end

  defp check_item(_item), do: :bad

  # As `Operator.Core.Front.open/3` resolves it: the full name below
  # Operator.Dyn., or its last part(s).
  defp screen?(screen, screens) do
    name = String.replace_prefix(screen, "Operator.Dyn.", "")
    Enum.any?(screens, &(&1 == name or String.ends_with?(&1, "." <> name)))
  end

  defp short(text), do: String.slice(text, 0, 120)

  defp paste_error(:no_login_started),
    do: "Tap sign in first, then paste the code its page shows."

  defp paste_error({:started_for, other}),
    do: "The sign-in in progress is for #{Auth.label(other)}: tap sign in again."

  defp paste_error(:state_mismatch), do: "That code is from another sign-in: tap sign in again."
  defp paste_error(:no_code), do: "No code in that: paste what the page shows (code#state)."

  # ── pages ──

  defp page(:main, a, t) do
    accounts =
      for provider <- Auth.providers() do
        st = a.auth[provider]
        value = if st.signed_in, do: st.email || "signed in", else: "not signed in"

        UI.item(Auth.label(provider), value, {:open, :accounts}, t,
          color: if(st.signed_in, do: "fg", else: "dim")
        )
      end

    renderer = Term.renderer()
    other = if renderer == :native, do: :term, else: :native

    rows =
      [UI.heading("accounts", t)] ++
        accounts ++
        [
          UI.heading("model", t),
          UI.item(short_model(a.model), provider_of(a.model), {:open, :model}, t),
          UI.heading("session", t),
          UI.item("new session", "", :new_session, t),
          UI.item("resume a session", "", {:open, :sessions}, t),
          UI.heading("display", t),
          UI.item("renderer: md:#{renderer}", "tap for md:#{other}", :toggle_renderer, t),
          UI.line(renderer_hint(renderer), t, "dim", text_size: t.text_size - 1),
          UI.heading("usage and devices", t),
          UI.item("usage", "5h / weekly, tokens", :usage, t),
          UI.item("cluster", "pair Operators over local TLS", :cluster, t),
          UI.item("components", "the component library, in the front", :components, t)
        ] ++
        yours_rows(a.yours, t) ++
        [
          UI.heading("diagnostics", t),
          UI.item("diagnostics", "updates, spend, dyn", :diagnostics, t)
        ] ++ approval_rows(a, t)

    {"menu", rows}
  end

  defp page(:accounts, a, t) do
    providers =
      Enum.flat_map(Auth.providers(), fn provider ->
        [UI.heading(Auth.label(provider), t), UI.line(auth_line(a.auth[provider]), t)] ++
          account_actions(provider, a, t)
      end)

    mac = [
      UI.heading("from the Mac", t),
      UI.line("mix operator.login anthropic|openai shows a QR and six words.", t, "dim"),
      UI.actions(t, [UI.link("scan a login QR", :scan_qr, t)])
    ]

    {"menu › accounts", providers ++ mac}
  end

  defp page(:model, a, t) do
    rows =
      Enum.flat_map(Models.by_provider(a.auth), fn {provider, signed_in, models} ->
        body =
          if signed_in,
            do: Enum.map(models, &model_item(&1, a.model, t)),
            else: [
              UI.line(
                "sign in under accounts to add these",
                t,
                "dim"
              )
            ]

        [UI.heading(Auth.label(provider), t) | body]
      end)

    custom = [
      UI.heading("custom", t),
      UI.line("any req_llm spec, or omp's provider/model", t, "dim"),
      UI.actions(t, [
        UI.field(a.model_draft, "anthropic:… or openai_codex:…", :model_draft, t, weight: 1),
        UI.chip("save", :save_model, t)
      ])
    ]

    {"menu › model", rows ++ custom}
  end

  defp page(:sessions, a, t) do
    sessions = a.sessions
    now = System.os_time(:second)

    items =
      for s <- sessions do
        current = s.path == a.path

        title = if s.title in [nil, ""], do: "(untitled)", else: s.title

        UI.item(title, age(now - s.mtime), {:resume, s.path}, t,
          mark: current,
          color: if(current, do: "user", else: "fg")
        )
      end

    empty = if items == [], do: [UI.line("no saved sessions yet", t, "dim")], else: []

    rows =
      [UI.item("new session", "", :new_session, t), UI.heading("saved, newest first", t)] ++
        items ++ empty

    {"menu › sessions", rows}
  end

  defp yours_rows({[], nil}, _t), do: []

  defp yours_rows({rows, problem}, t) do
    items =
      for r <- rows do
        detail = if r.found, do: r.detail, else: "no screen #{r.screen}"
        UI.item(r.label, detail, {:yours, r.screen}, t, color: if(r.found, do: "fg", else: "dim"))
      end

    problem =
      if problem,
        do: [UI.line("Operator.Dyn.Menu: " <> problem, t, "error", text_size: t.text_size - 1)],
        else: []

    [UI.heading("yours", t) | items] ++ problem
  end

  defp approval_rows(%{auto_approve: true}, t) do
    [
      UI.heading("approvals", t),
      UI.item("approve all", "on · tap to turn off", :auto_approve_off, t, color: "accent"),
      UI.line("self-changes activate without asking (still on probation)", t, "dim",
        text_size: t.text_size - 1
      )
    ]
  end

  defp approval_rows(_a, t) do
    [
      UI.heading("approvals", t),
      UI.line("ask each time", t),
      UI.line("approve all activates each self-change without asking", t, "dim",
        text_size: t.text_size - 1
      ),
      UI.actions(t, [auto_approve_chip(t)])
    ]
  end

  # Turning approve all on takes the screen lock (a native view on the phone).
  defp auto_approve_chip(t) do
    if Term.platform() in [:android, :ios] do
      Mob.UI.native_view(ApproveButton,
        id: :auto_approve_on,
        notify: self(),
        subject: AutoApprove.subject(),
        label: "approve all",
        title: "Approve all self-changes",
        subtitle: "Operator activates its own code changes without asking",
        text_color: Term.color(t, "user"),
        background: Term.color(t, "code_bg"),
        text_size: t.text_size - 1,
        font: Term.markdown_props(t).font_regular
      )
    else
      UI.link("approve all", :auto_approve_on, t)
    end
  end

  defp account_actions(provider, %{confirm: provider}, t) do
    [
      UI.actions(t, [
        UI.link("confirm sign out", {:confirm_sign_out, provider}, t, color: "error"),
        UI.link("cancel", :cancel_sign_out, t)
      ])
    ]
  end

  defp account_actions(provider, a, t) do
    action =
      if a.auth[provider].signed_in,
        do: UI.link("sign out", {:sign_out, provider}, t, color: "error"),
        else: UI.link("sign in", {:sign_in, provider}, t)

    reauth =
      if a.auth[provider].signed_in,
        do: [UI.link("sign in again", {:sign_in, provider}, t)],
        else: []

    [UI.actions(t, [action | reauth])] ++ paste_row(provider, a, t)
  end

  # Anthropic's page may show `code#state` instead of coming back.
  defp paste_row(provider, %{pending: provider} = a, t) do
    [
      UI.line("If the page shows a code, paste it here:", t, "dim"),
      UI.actions(t, [
        UI.field(a.code, "code#state", :code, t, weight: 1, on_submit: {self(), :code}),
        UI.chip("submit", :paste_code, t)
      ])
    ]
  end

  defp paste_row(_provider, _a, _t), do: []

  defp model_item(model, current, t) do
    chosen = Models.same?(model.spec, current)
    context = if model.context, do: context_label(model.context), else: ""

    UI.item(model.name, context, {:pick_model, model.spec}, t,
      mark: chosen,
      bold: chosen,
      color: if(chosen, do: "user", else: "fg")
    )
  end

  # ── text ──

  defp short_model(model), do: model |> String.split(["/", ":"]) |> List.last()

  defp provider_of(model) do
    case Auth.provider_for_model(model) do
      {:ok, provider} -> Auth.label(provider)
      :error -> model |> String.split(":") |> hd()
    end
  end

  defp renderer_hint(:native), do: "native Markdown views, selectable"
  defp renderer_hint(:term), do: "Operator's own terminal renderer"

  defp context_label(tokens) when tokens >= 1_000_000 and rem(tokens, 1_000_000) == 0,
    do: "#{div(tokens, 1_000_000)}M"

  defp context_label(tokens), do: "#{div(tokens, 1000)}k"

  defp age(s) when s < 3600, do: "#{max(div(s, 60), 1)}m ago"
  defp age(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp age(s), do: "#{div(s, 86_400)}d ago"

  defp auth_line(%{signed_in: false}), do: "not signed in"

  defp auth_line(%{email: email, expires: expires}) do
    who = if email, do: "signed in as #{email}", else: "signed in"
    minutes = div((expires || 0) - System.os_time(:millisecond), 60_000)

    token =
      if minutes > 0,
        do: "token good for #{div(minutes, 60)} h #{rem(minutes, 60)} min",
        else: "token refreshes on the next call"

    "#{who} · #{token}"
  end
end
