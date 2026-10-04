defmodule Operator.Core.Front do
  @moduledoc """
  The front: the screens the user builds (PLAN.md "Front and back"). Front
  screens are Dyn `:screen` modules of the current generation; this Core
  process decides which one shows and keeps it running, and
  `Operator.ShellScreen` draws it full-bleed with the toggle over it.

  **Hosting.** The open front screen runs in its own process,
  `Operator.Core.Front.Host`, started and monitored here; the shell gets
  only its view (a render tree, as data) through `subscribe/1`. So the
  toggle, the terminal, approval and rescue never run front code: a front
  that raises shows its error and stacktrace where it was drawn (the Host
  crashed; its crash counts against its generation's probation, so
  repeated crashes revert it), one that hangs leaves its last view, and the
  toggle works either way. Showing the front again (`show/2`) starts a
  host that isn't running, so toggling back and forth retries a crashed
  screen. The host outlives the shell: switching to the terminal and back
  keeps the front's state.

  **Which screen.** The host's navigation stack (the front's own
  push/pop) is saved in the settings (`front_stack`) as screen names
  (`"Showcase.GalleryScreen"`, the module name below `Operator.Dyn.`), and
  reopened at the next launch. With nothing saved, or none of it left in
  the current generation, the front opens `Operator.Dyn.Front.start/0`'s
  screen, or the first screen there is. `open/2` (the agent's
  `front_open` tool) switches the front to any front screen. A new
  generation (activation, revert) restarts the host on the same screens.

  **Settings in Dyn.** `Operator.Dyn.Front` may define `start/0` (a
  screen module) and `toggle/0`, the toggle's symbol: `:dial` (Operator's
  logo, the default) or `{:text, glyph}` (up to 8 characters). They're read
  in a contained process (timeout, heap limit) and validated; anything
  else is ignored. `toggle/0` (this module's) is a `:persistent_term` read
  for screens to draw it.

  **Themes.** `Mob.Theme` is global, and front screens may change it. The
  front's theme is put back when it shows, the terminal's
  (`Operator.Core.Term.install/0`) when it hides.
  """
  use GenServer

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Registry
  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Front.Host
  alias Operator.Core.Settings
  alias Operator.Core.Term

  require Logger

  @toggle_key {__MODULE__, :toggle}
  @settings_timeout_ms 2_000
  @settings_max_heap_words 1_000_000
  @max_error_bytes 6_000

  @type toggle :: :dial | {:text, String.t()}
  @type view :: {:tree, map()} | {:error, String.t()} | {:note, String.t()}
  @type snapshot :: %{view: view(), host: pid() | nil}

  # ── API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The front's current view and host; afterwards the caller gets
  `{:operator_front, snapshot}` whenever either changes, until it exits.
  """
  @spec subscribe(GenServer.server()) :: snapshot()
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc """
  The front is on screen (the shell mounted; `env` is its platform,
  insets and size class): puts the front's theme back and starts a host
  if none runs (first show, or the last one crashed).
  """
  @spec show(map(), GenServer.server()) :: snapshot()
  def show(env, server \\ __MODULE__), do: GenServer.call(server, {:show, env}, 10_000)

  @doc "The front is off screen: the terminal's theme comes back."
  @spec hide(GenServer.server()) :: :ok
  def hide(server \\ __MODULE__), do: GenServer.call(server, :hide, 10_000)

  @doc """
  Switches the front to the screen `name`: a name `screens/1` lists, the
  full module name, or a unique last part of one (`"Slider"`).
  """
  @spec open(String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :unknown_screen | {:ambiguous, [String.t()]}}
  def open(name, server \\ __MODULE__), do: GenServer.call(server, {:open, name}, 10_000)

  @doc "The current generation's front screens, by name."
  @spec screens(GenServer.server()) :: [String.t()]
  def screens(server \\ __MODULE__), do: GenServer.call(server, :screens)

  @doc """
  What the front shows: the screen stack (names, top first), `:running`
  or the error or note on screen, and whether it is on screen.
  """
  @spec status(GenServer.server()) :: %{
          stack: [String.t()],
          view: :running | {:error, String.t()} | {:note, String.t()},
          visible: boolean(),
          toggle: toggle()
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Re-reads the front's settings and screens (after the seed, say)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :refresh)
    :ok
  end

  @doc "The toggle's symbol (no process call: screens draw it on every render)."
  @spec toggle() :: toggle()
  def toggle, do: :persistent_term.get(@toggle_key, :dial)

  @doc """
  Navigates the app (mob's router, as `Mob.Test` does) from outside a
  screen: `{:push, module, params}`, `{:pop}`, ...
  """
  @spec navigate(tuple()) :: :ok
  def navigate(action), do: GenServer.call(:mob_screen, {:navigate, action}, 10_000)

  @doc "Validates `Operator.Dyn.Front.toggle/0`'s value."
  @spec validate_toggle(term()) :: {:ok, toggle()} | {:error, String.t()}
  def validate_toggle(:dial), do: {:ok, :dial}

  def validate_toggle({:text, text}) when is_binary(text) do
    if String.length(String.trim(text)) in 1..8,
      do: {:ok, {:text, String.trim(text)}},
      else: {:error, "a {:text, glyph} toggle needs 1 to 8 characters"}
  end

  def validate_toggle(other),
    do: {:error, "toggle/0 must return :dial or {:text, glyph}, got #{inspect(other, limit: 5)}"}

  @doc "The system prompt section on the front: what it is, how a front screen is written."
  @spec agent_guide() :: String.t()
  def agent_guide do
    """
    ## The front: the app the user sees

    The front is the app's UI, Dyn screens (`use Mob.Screen`) the user builds with you. The \
    toggle, Operator's logo in the upper left corner, is drawn over every screen: keep the \
    top-left 56×48 dp of a front screen free of anything tappable. Nothing can hide, cover or \
    move it; only its symbol is yours, `Operator.Dyn.Front.toggle/0`: `:dial` (the logo, \
    default) or `{:text, "☎"}` (1 to 8 characters).

    A front change is a Dyn change like any other, and the front restarts on the new code. \
    `front_screens` lists the screens and says which is open and whether it crashed, \
    `front_open` switches the front to a screen (when asked, or when a screen has no way to \
    it), `front_screenshot` shows you the front: look at it after a change is active.

    The default front is the widget gallery: `Operator.Dyn.Showcase.GalleryScreen` lists most \
    Mishka widgets, each with its own screen `Operator.Dyn.Showcase.Components.<Name>` \
    (`showcase/components/<name>.ex`, named in the `mishka` guide; also `showcase/page.ex`, \
    `showcase/kit.ex`, `theme_bar.ex`): worked examples, `dyn_read` one before you use its widget. \
    `Operator.Dyn.Front.start/0` is the screen the front opens on. Reverting to the seed's \
    generation (Diagnostics → Rescue) restores the defaults.

    A front screen is a Dyn screen (Building with mob, above) with these differences: \
    `push_screen`, `pop_screen` and `reset_to` go between front screens only, and Android's \
    back button goes to the terminal; `Mob.Theme.set/1` themes the front, the terminal keeps \
    its own theme. The open screen runs in a process of its own: plugin results, permission \
    answers and timers (`Process.send_after(self(), ...)`) all come to its `handle_info/2`, \
    also from `mount/3`. It keeps its state while the user is in the terminal, and restarts \
    when a new generation activates. If it raises, the front shows the error (the toggle \
    still works) and `front_screens` reports it; 3 crashes within 60 s of a new generation \
    revert it.
    """
  end

  # ── server ──

  @impl true
  def init(opts) do
    keeper = Keyword.get(opts, :keeper, Dyn.Keeper)
    _ = Dyn.subscribe(keeper)

    s = %{
      keeper: keeper,
      dir: Keyword.get_lazy(opts, :dir, &Operator.Paths.data_dir/0),
      subs: %{},
      host: nil,
      mon: nil,
      stack: [],
      gen: nil,
      start: nil,
      screens: %{},
      view: {:note, ""},
      visible: false,
      env: nil,
      theme: nil
    }

    {:ok, %{s | stack: Settings.front_stack(s.dir)}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s) do
    subs =
      if Map.has_key?(s.subs, pid), do: s.subs, else: Map.put(s.subs, pid, Process.monitor(pid))

    {:reply, snapshot(s), %{s | subs: subs}}
  end

  def handle_call({:show, env}, _from, s) do
    if s.theme, do: Mob.Theme.set(s.theme)
    s = %{s | visible: true, env: env} |> sync()
    if s.host, do: Host.put_env(s.host, env)
    s = if s.host, do: s, else: start_host(s)
    {:reply, snapshot(s), s}
  end

  def handle_call(:hide, _from, s), do: {:reply, :ok, hide_front(s)}

  def handle_call({:open, name}, _from, s) do
    s = sync(s)

    case resolve(name, s.screens) do
      {:ok, found} ->
        s = %{s | stack: [found]} |> save_stack() |> restart_host()
        {:reply, {:ok, found}, s}

      error ->
        {:reply, error, s}
    end
  end

  def handle_call(:screens, _from, s) do
    s = sync(s)
    {:reply, s.screens |> Map.keys() |> Enum.sort(), s}
  end

  def handle_call(:status, _from, s) do
    view =
      case s.view do
        {:tree, _} -> :running
        other -> other
      end

    {:reply, %{stack: s.stack, view: view, visible: s.visible, toggle: toggle()}, s}
  end

  @impl true
  def handle_cast(:refresh, s), do: {:noreply, s |> sync() |> restart_if_running()}

  @impl true
  def handle_info({:operator_front_host, host, {:view, tree}}, %{host: host} = s),
    do: {:noreply, broadcast(%{s | view: {:tree, tree}})}

  def handle_info({:operator_front_host, host, {:stack, mods}}, %{host: host} = s) do
    names = Enum.map(mods, &name/1)
    {:noreply, if(names == s.stack, do: s, else: save_stack(%{s | stack: names}))}
  end

  def handle_info({:operator_front_host, _old_host, _message}, s), do: {:noreply, s}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{mon: ref} = s) do
    Logger.warning("[front] the front screen stopped: #{inspect(reason, limit: 10)}")
    {:noreply, broadcast(%{s | host: nil, mon: nil, view: {:error, crash_text(reason)}})}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case s.subs do
      %{^pid => ^ref} ->
        subs = Map.delete(s.subs, pid)
        s = %{s | subs: subs}
        # The shell went (popped or replaced): the terminal is in front.
        {:noreply, if(subs == %{} and s.visible, do: hide_front(s), else: s)}

      _ ->
        {:noreply, s}
    end
  end

  # The default front was just installed: it opens on its start screen (the
  # gallery), whatever showed before.
  def handle_info({:operator_dyn, %{type: :activated, seed: true}}, s),
    do: {:noreply, %{s | stack: []} |> save_stack() |> sync() |> restart_if_running()}

  def handle_info({:operator_dyn, %{type: type}}, s)
      when type in [:activated, :reverted, :safe_mode],
      do: {:noreply, s |> sync() |> restart_if_running()}

  # A generation rebuilt for a new Core is registered now (same number, new
  # screens), or its rebuild failed.
  def handle_info({:operator_dyn, %{type: type}}, s) when type in [:loaded, :load_failed],
    do: {:noreply, %{s | gen: nil} |> sync() |> restart_if_running()}

  def handle_info(_message, s), do: {:noreply, s}

  # Not yet shown: the host starts when the front is.
  defp restart_if_running(%{host: nil, visible: false} = s), do: s
  defp restart_if_running(s), do: restart_host(s)

  defp restart_host(s), do: s |> stop_host() |> start_host()

  defp stop_host(%{host: nil} = s), do: s

  defp stop_host(s) do
    Process.demonitor(s.mon, [:flush])
    # An orderly stop, not a crash of the front's generation.
    Dyn.Keeper.unwatch(s.keeper, s.host)
    Process.exit(s.host, :kill)
    %{s | host: nil, mon: nil}
  end

  defp start_host(s) do
    case stack_modules(s) do
      [] ->
        broadcast(%{s | view: {:note, note(s)}})

      stack ->
        screens = s.screens |> Map.values() |> MapSet.new()
        {pid, mon} = Host.start(self(), stack, env(s), &MapSet.member?(screens, &1))
        # Blank until the new host's first view: not the last one's error or
        # tree (whose taps went to a process that's gone).
        broadcast(%{s | host: pid, mon: mon, view: {:note, ""}})
    end
  end

  # The saved names that still exist, else the start screen.
  defp stack_modules(s) do
    case for(name <- s.stack, {:ok, mod} <- [Map.fetch(s.screens, name)], do: {mod, %{}}) do
      [] -> if s.start, do: [{Map.fetch!(s.screens, s.start), %{}}], else: []
      stack -> stack
    end
  end

  defp env(%{env: nil}) do
    %{
      platform: :android,
      safe_area: %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0},
      size_class: Mob.SizeClass.placeholder()
    }
  end

  defp env(%{env: env}), do: env

  defp note(s) do
    cond do
      Dyn.safe_mode?(s.keeper) ->
        "Safe mode: Operator's last launches failed, so it started without its Dyn layer " <>
          "and there's no front. The terminal and Diagnostics → Rescue still work."

      Dyn.rebuilding(s.keeper) ->
        "Preparing the front: Operator was updated, so its screens are being rebuilt " <>
          "for the new version on the phone (about half a minute). The terminal works meanwhile."

      Seed.running?() ->
        "Preparing the default front (the widget gallery). The first launch compiles it " <>
          "on the phone, which takes about half a minute."

      not_loaded?(s) ->
        "Generation #{s.gen} didn't load this launch, so there's no front. Diagnostics says " <>
          "why; ask the agent in the terminal to fix it, or revert from Rescue."

      true ->
        "No front screens yet. Ask the agent in the terminal to build one."
    end
  end

  # The current generation has modules, but none of them is registered.
  defp not_loaded?(%{gen: gen, keeper: keeper}) when is_integer(gen) and gen > 0 do
    Registry.entries(keeper) == %{} and
      match?({:ok, %{modules: [_ | _]}}, Dyn.generation(gen, keeper))
  end

  defp not_loaded?(_s), do: false

  defp crash_text({%{__exception__: true} = e, stack}) when is_list(stack),
    do: trim(Exception.format(:error, e, stack))

  defp crash_text(reason), do: trim("exited: " <> Exception.format_exit(reason))

  defp trim(text) when byte_size(text) > @max_error_bytes,
    do: binary_part(text, 0, @max_error_bytes) <> "\n…"

  defp trim(text), do: text

  # ── generations and settings ──

  # Brings the screens and settings up to the registry's generation.
  defp sync(s) do
    gen = Registry.generation(s.keeper)

    if gen == s.gen do
      s
    else
      screens = s.keeper |> Dyn.screens() |> Map.new()
      {start, toggle} = settings(s.keeper, screens)
      :persistent_term.put(@toggle_key, toggle)
      %{s | gen: gen, screens: screens, start: start}
    end
  end

  defp settings(keeper, screens) do
    first = screens |> Map.keys() |> Enum.sort() |> List.first()

    case Dyn.lookup({:module, "Front"}, keeper) do
      {:ok, mod} ->
        {start, toggle} = read_settings(mod)
        by_module = Map.new(screens, fn {name, m} -> {m, name} end)
        {Map.get(by_module, start, first), toggle}

      :error ->
        {first, :dial}
    end
  end

  # Unlinked, with a timeout and a heap limit: settings that raise or hang
  # fall back to the defaults.
  defp read_settings(mod) do
    parent = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @settings_max_heap_words,
          kill: true,
          error_logger: false
        })

        start = if function_exported?(mod, :start, 0), do: mod.start()
        toggle = if function_exported?(mod, :toggle, 0), do: mod.toggle(), else: :dial
        send(parent, {ref, start, toggle})
      end)

    receive do
      {^ref, start, toggle} ->
        Process.demonitor(mref, [:flush])
        {start, valid_toggle(toggle)}

      {:DOWN, ^mref, :process, ^pid, reason} ->
        Logger.warning("[front] Operator.Dyn.Front crashed: #{inspect(reason, limit: 10)}")
        {nil, :dial}
    after
      @settings_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(mref, [:flush])
        {nil, :dial}
    end
  end

  defp valid_toggle(value) do
    case validate_toggle(value) do
      {:ok, toggle} ->
        toggle

      {:error, why} ->
        Logger.warning("[front] toggle ignored: #{why}")
        :dial
    end
  end

  defp resolve(name, screens) do
    name = name |> String.trim() |> String.replace_prefix("Operator.Dyn.", "")

    if Map.has_key?(screens, name) do
      {:ok, name}
    else
      case Enum.filter(Map.keys(screens), &String.ends_with?(&1, "." <> name)) do
        [one] -> {:ok, one}
        [] -> {:error, :unknown_screen}
        many -> {:error, {:ambiguous, Enum.sort(many)}}
      end
    end
  end

  defp name(mod), do: mod |> Compiler.logical() |> String.replace_prefix("Operator.Dyn.", "")

  defp save_stack(s) do
    :ok = Settings.put_front_stack(s.stack, s.dir)
    s
  end

  # ── showing ──

  defp hide_front(%{visible: false} = s), do: s

  defp hide_front(s) do
    theme = Mob.Theme.current()
    :ok = Term.install()
    %{s | visible: false, theme: theme}
  end

  defp snapshot(s), do: %{view: s.view, host: s.host}

  defp broadcast(s) do
    for pid <- Map.keys(s.subs), do: send(pid, {:operator_front, snapshot(s)})
    s
  end
end
