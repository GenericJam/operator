defmodule Operator.Core.DynTheme do
  @moduledoc """
  The terminal theme as a Dyn artifact (DESIGN.md §2, the first one): the
  current generation may define `Operator.Dyn.Theme` with `overrides/0`,
  and the chat screen draws with the default theme plus those overrides.

  Dyn code never runs in the screen: `refresh/1` calls `overrides/0` in a
  contained process (timeout, heap limit), keeps only the keys and values
  `validate/1` accepts, and installs the result with
  `Operator.Core.Term.put_theme/1`. It runs at boot (after the Dyn layer
  loads) and on every activation or revert; subscribers get
  `{:operator_theme, :changed}` so they redraw. A theme that fails is
  ignored (the default stays) and its reason kept in `status/1`.

  Accepted overrides: `palette` (#{inspect(~w(bg bar fg dim user tool error notice heading code code_bg link accent))}
  → `0xAARRGGBB` integers), `text_size` (10..24), `line_height`
  (1.0..2.0), `padding` (0..24), `tool_result_lines` and `thinking_lines`
  (0..20).
  """
  use GenServer

  alias Operator.Core.Dyn
  alias Operator.Core.Term

  require Logger

  @palette ~w(bg bar fg dim user tool error notice heading code code_bg link accent)
  @ranges %{
    text_size: {10, 24},
    padding: {0, 24},
    tool_result_lines: {0, 20},
    thinking_lines: {0, 20}
  }
  @timeout_ms 2_000
  @max_heap_words 2_000_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Re-reads the current generation's theme and installs it."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :refresh, 10_000), else: :ok
  end

  @doc "`{:ok, module | :default}` or `{:error, reason}` for the theme in use."
  @spec status(GenServer.server()) :: {:ok, module() | :default} | {:error, String.t()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Sends the caller `{:operator_theme, :changed}` whenever the theme changes."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, {:subscribe, self()}), else: :ok
  end

  @doc "For the system prompt: how the agent changes the theme."
  @spec agent_guide() :: String.t()
  def agent_guide do
    """
    The chat's colours and sizes are yours to change: define `Operator.Dyn.Theme` in the \
    Dyn layer with `def overrides, do: %{...}` and propose it like any change. Keys: \
    `palette` (#{Enum.join(@palette, ", ")}; values `0xAARRGGBB` integers), `text_size` \
    (10..24), `line_height` (1.0..2.0), `padding` (0..24), `tool_result_lines` and \
    `thinking_lines` (0..20). Anything else is ignored; a theme that raises is not applied.
    """
  end

  @doc """
  The overrides `Term.put_theme/1` may take from `raw`, or `{:error,
  reason}` naming the first bad key or value.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case check(key, value) do
        {:ok, k, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate(other),
    do: {:error, "overrides/0 must return a map, got #{inspect(other, limit: 5)}"}

  defp check(key, palette) when key in [:palette, "palette"] and is_map(palette) do
    Enum.reduce_while(palette, {:ok, :palette, %{}}, fn {name, color}, {:ok, k, acc} ->
      name = to_string(name)

      cond do
        name not in @palette ->
          {:halt, {:error, "unknown palette colour #{inspect(name)}"}}

        not (is_integer(color) and color in 0..0xFFFFFFFF) ->
          {:halt, {:error, "#{name} must be 0xAARRGGBB"}}

        true ->
          {:cont, {:ok, k, Map.put(acc, name, color)}}
      end
    end)
  end

  defp check(key, value) when key in [:line_height, "line_height"] do
    if is_number(value) and value >= 1.0 and value <= 2.0,
      do: {:ok, :line_height, value * 1.0},
      else: {:error, "line_height must be 1.0..2.0"}
  end

  defp check(key, value) do
    case Enum.find(@ranges, fn {k, _} -> key in [k, Atom.to_string(k)] end) do
      {k, {lo, hi}} when is_integer(value) and value >= lo and value <= hi -> {:ok, k, value}
      {k, {lo, hi}} -> {:error, "#{k} must be an integer #{lo}..#{hi}"}
      nil -> {:error, "unknown theme key #{inspect(key)}"}
    end
  end

  # ── server ──

  @impl true
  def init(opts) do
    _ = Dyn.subscribe(Keyword.get(opts, :keeper, Dyn.Keeper))
    {:ok, %{keeper: Keyword.get(opts, :keeper, Dyn.Keeper), status: {:ok, :default}, subs: %{}}}
  end

  @impl true
  def handle_call(:refresh, _from, s), do: {:reply, :ok, apply_theme(s)}
  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  def handle_call({:subscribe, pid}, _from, s) do
    subs =
      if Map.has_key?(s.subs, pid), do: s.subs, else: Map.put(s.subs, pid, Process.monitor(pid))

    {:reply, :ok, %{s | subs: subs}}
  end

  @impl true
  def handle_info({:operator_dyn, %{type: type}}, s)
      when type in [:activated, :reverted, :safe_mode, :loaded],
      do: {:noreply, apply_theme(s)}

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subs do
      %{^pid => ^ref} -> {:noreply, %{s | subs: Map.delete(s.subs, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp apply_theme(s) do
    status =
      case Dyn.lookup({:module, "Theme"}, s.keeper) do
        {:ok, mod} -> load(mod)
        :error -> {:ok, :default, %{}}
      end

    {overrides, status} =
      case status do
        {:ok, mod, overrides} ->
          {overrides, {:ok, mod}}

        {:error, reason} ->
          Logger.warning("[dyn_theme] not applied: #{reason}")
          {%{}, {:error, reason}}
      end

    # Keep the renderer the user chose (the md: chip); the rest comes from the theme.
    renderer = Term.theme().renderer
    :ok = Term.put_theme(Map.put(overrides, :renderer, renderer))
    for pid <- Map.keys(s.subs), do: send(pid, {:operator_theme, :changed})
    %{s | status: status}
  end

  # Unlinked: a theme that raises, hangs or blows its heap can't take this
  # process (or the screen) down.
  defp load(mod) do
    parent = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false})
        send(parent, {ref, mod.overrides()})
      end)

    receive do
      {^ref, raw} ->
        Process.demonitor(mref, [:flush])
        with {:ok, overrides} <- validate(raw), do: {:ok, mod, overrides}

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, "overrides/0 crashed: #{Exception.format_exit(reason)}"}
    after
      @timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(mref, [:flush])
        {:error, "overrides/0 took over #{@timeout_ms} ms"}
    end
  end
end
