defmodule Operator.Core.Front.Host do
  @moduledoc """
  The process front screens run in. `Operator.Core.Front` starts one per
  front (monitored, not linked) and the shell only ever gets data from it,
  so front code never runs in the shell, the terminal or any other Core
  process: a front that raises, exits or hangs stops this process (or
  leaves its last view on screen), and the toggle and the terminal keep
  working. Its crash counts against its Dyn generation (the screens'
  `mount/3` registers it with the Keeper, `Operator.Core.Dyn.Compiler`).

  It does for the front what `Mob.Screen.Server` and `Mob.Router` do for a
  mob screen: holds the front's own navigation stack (the top first; a
  screen below the top that was never mounted is mounted when it comes
  back on top), runs the top screen's `mount/3`, `handle_info/2` and
  `render/1`, and applies the navigation a screen asks for with
  `Mob.Socket.push_screen/3`, `pop_screen/1`, `pop_to/2`, `pop_to_root/1`
  and `reset_to/3`, within the front and only to front screens. Every
  changed view goes to the front as `{:operator_front_host, pid, {:view,
  tree}}`, expanded (Mishka composites, `:list`s) with this process as the
  event target, so the front's taps and changes come straight here; the
  stack goes as `{:operator_front_host, pid, {:stack, modules}}`.

  Native views (`Mob.UI.native_view/2`) aren't supported in the front: the
  shell would have to run their component code, so they're drawn as a note.
  """

  alias Operator.Core.Files

  require Logger

  @stop_timeout_ms 3_000
  @terminate_timeout_ms 2_000
  @tracked_stack {__MODULE__, :tracked_stack}

  @type env :: %{platform: atom(), safe_area: map(), size_class: term()}

  @doc """
  Starts a host for `stack` (`[{module, params}]`, the top first) and
  returns `{pid, monitor, capability_key}`. `screen?` says whether a module
  may be opened in the front. Native capability events must carry the
  unguessable key; front code never receives it.
  """
  @spec start(pid(), [{module(), map()}], env(), (module() -> boolean())) ::
          {pid(), reference(), reference()}
  def start(front, [_ | _] = stack, env, screen?) do
    capability_key = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        front_monitor = Process.monitor(front)
        stack = for {mod, params} <- stack, do: %{module: mod, params: params, socket: nil}

        s = %{
          front: front,
          front_monitor: front_monitor,
          capability_key: capability_key,
          env: env,
          screen?: screen?,
          stack: stack,
          last: nil
        }

        remember(s)

        try do
          s |> ensure_mounted() |> report_stack() |> paint() |> loop()
        after
          terminate_entries(Process.get(@tracked_stack, []), :shutdown)
        end
      end)

    {pid, monitor, capability_key}
  end

  @doc """
  Stops a host after giving every mounted screen its optional `terminate/2`
  callback. A cleanup that outlasts its deadline gets the host killed, which
  also counts as stopped.
  """
  @spec stop(pid(), timeout()) :: :ok | :timeout
  def stop(host, timeout \\ @stop_timeout_ms) when is_pid(host) do
    ref = make_ref()
    monitor = Process.monitor(host)
    send(host, {__MODULE__, :stop, self(), ref})

    receive do
      {__MODULE__, :stopped, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^host, _reason} ->
        :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        Process.exit(host, :kill)
        :timeout
    end
  end

  @doc "Sends the host the shell's environment (insets, size class), for the next mount."
  @spec put_env(pid(), env()) :: :ok
  def put_env(host, env) do
    send(host, {__MODULE__, :env, env})
    :ok
  end

  defp loop(s) do
    remember(s)

    receive do
      {__MODULE__, :stop, from, ref} ->
        terminate_entries(s.stack, :shutdown)
        Process.put(@tracked_stack, [])
        send(from, {__MODULE__, :stopped, ref})
        :ok

      {:DOWN, front_monitor, :process, front, _reason}
      when front_monitor == s.front_monitor and front == s.front ->
        :ok

      {__MODULE__, :env, env} ->
        s |> Map.put(:env, env) |> loop()

      message ->
        s |> handle(message) |> paint() |> loop()
    end
  end

  # ── events and navigation ──

  defp handle(
         %{capability_key: key} = s,
         {__MODULE__, :native, key, message}
       ) do
    :ok = Files.grant_capability(message)
    handle(s, message)
  end

  defp handle(%{stack: [top | rest]} = s, message) do
    socket =
      case top.module.handle_info(message, top.socket) do
        {:noreply, %Mob.Socket{} = socket} ->
          socket

        other ->
          raise "#{inspect(top.module)}.handle_info/2 must return {:noreply, socket}, got: " <>
                  short(other)
      end

    action = socket.__mob__.nav_action
    socket = Mob.Socket.put_mob(socket, :nav_action, nil)
    s = %{s | stack: [%{top | socket: socket} | rest]}
    remember(s)
    navigate(s, action)
  end

  defp navigate(s, nil), do: s

  defp navigate(s, action) do
    s
    |> nav(action)
    |> ensure_mounted()
    |> report_stack()
  end

  defp nav(s, {:push, dest, params}),
    do: replace_stack(s, [entry(s, dest, params) | s.stack], [])

  defp nav(%{stack: [top, _ | _] = stack} = s, {:pop}),
    do: replace_stack(s, tl(stack), [top])

  defp nav(s, {:pop}), do: s

  defp nav(s, {:pop_to_root}) do
    root = List.last(s.stack)
    replace_stack(s, [root], Enum.drop(s.stack, -1))
  end

  defp nav(s, {:pop_to, dest}) do
    case Enum.drop_while(s.stack, &(&1.module != dest)) do
      [] ->
        s

      stack ->
        removed = Enum.take(s.stack, length(s.stack) - length(stack))
        replace_stack(s, stack, removed)
    end
  end

  defp nav(s, {:reset, dest, params}),
    do: replace_stack(s, [entry(s, dest, params)], s.stack)

  defp nav(s, {:reset, dest, params, _transition}), do: nav(s, {:reset, dest, params})
  defp nav(s, {:reset, dest, params, _transition, :all}), do: nav(s, {:reset, dest, params})
  # The front has no tabs.
  defp nav(s, _other), do: s

  defp entry(s, dest, params) do
    if is_atom(dest) and s.screen?.(dest),
      do: %{module: dest, params: params, socket: nil},
      else: raise(ArgumentError, "the front can only open front screens, not #{short(dest)}")
  end

  defp ensure_mounted(%{stack: [%{socket: nil} = top | rest]} = s) do
    s = %{s | stack: [mount(top, s.env) | rest]}
    remember(s)
    s
  end

  defp ensure_mounted(s), do: s

  defp mount(%{module: mod, params: params} = entry, env) do
    socket =
      mod
      |> Mob.Socket.new(platform: env.platform)
      |> Mob.Socket.assign(safe_area: env.safe_area, size_class: env.size_class)

    case mod.mount(params, %{}, socket) do
      {:ok, %Mob.Socket{} = socket} -> %{entry | socket: socket}
      other -> raise "#{inspect(mod)}.mount/3 must return {:ok, socket}, got: #{short(other)}"
    end
  end

  defp report_stack(s) do
    send(s.front, {:operator_front_host, self(), {:stack, Enum.map(s.stack, & &1.module)}})
    s
  end

  defp replace_stack(s, stack, removed) do
    next = %{s | stack: stack}
    remember(next)
    terminate_entries(removed, :normal)
    next
  end

  defp remember(s) do
    Process.put(@tracked_stack, s.stack)
    s
  end

  # In the host itself: cleanup is often bound to the caller (`Task.shutdown/2`
  # checks the owner, sensor streams stop for their subscriber only). A
  # watchdog bounds it: a cleanup still running at the deadline kills the host.
  defp terminate_entries(entries, reason) do
    entries =
      for %{module: mod, socket: %Mob.Socket{} = socket} <- entries,
          function_exported?(mod, :terminate, 2),
          do: {mod, socket}

    if entries != [] do
      host = self()

      watchdog =
        spawn(fn ->
          receive do
            :done -> :ok
          after
            @terminate_timeout_ms -> Process.exit(host, :kill)
          end
        end)

      Enum.each(entries, fn {mod, socket} -> terminate_entry(mod, socket, reason) end)
      send(watchdog, :done)
    end

    :ok
  end

  defp terminate_entry(mod, socket, reason) do
    mod.terminate(reason, socket)
  catch
    kind, error ->
      Logger.warning(
        "[front] #{inspect(mod)}.terminate/2 failed: " <>
          Exception.format(kind, error, __STACKTRACE__)
      )
  end

  # ── the view ──

  # Sent only when it changed; the theme counts (a theme switch redraws
  # with the same tree).
  defp paint(%{stack: [top | _]} = s) do
    tree =
      top.module.render(top.socket.assigns)
      |> Mob.Composite.expand(self())
      |> Mob.List.expand(Map.get(top.socket.__mob__, :list_renderers, %{}), self())
      |> without_native_views()

    hash = :erlang.phash2({tree, Mob.Theme.current()})

    if hash == s.last do
      s
    else
      send(s.front, {:operator_front_host, self(), {:view, tree}})
      %{s | last: hash}
    end
  end

  defp without_native_views(%{type: :native_view}) do
    %{
      type: :text,
      props: %{text: "(native views can't run in the front)", text_color: :muted},
      children: []
    }
  end

  defp without_native_views(%{children: [_ | _] = kids} = node),
    do: %{node | children: kids |> List.flatten() |> Enum.map(&without_native_views/1)}

  defp without_native_views(node), do: node

  defp short(term), do: inspect(term, limit: 10, printable_limit: 200)
end
