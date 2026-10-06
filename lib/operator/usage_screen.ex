defmodule Operator.UsageScreen do
  @moduledoc """
  Menu › usage (`Operator.MenuScreen`), drawn like the terminal
  (`Operator.TermUI`): per provider, how much of the subscription's 5-hour
  and weekly windows is used and when they reset, the last 429 and when it
  resets (`Operator.Core.Usage`); then the tokens, requests and cost of the
  shown session, today and all time, and per model.

  Opening the page asks the signed-in providers' usage endpoints
  (`Operator.Core.Usage.Fetch`) when their numbers are over
  #{div(300, 60)} minutes old; `[refresh]` asks at once. Params: `:model`
  and `:path` (the shown session), `:data_dir` (default
  `Operator.Paths.data_dir/0`), `:signed_in` (the providers to ask; default
  the signed-in ones) and `:refresh` (`fn dir, provider -> :ok | {:error,
  message} end`, default `Operator.Core.Usage.Fetch.refresh/2`).
  """
  use Mob.Screen

  alias Operator.Auth
  alias Operator.Core.Budget
  alias Operator.Core.Session
  alias Operator.Core.Term
  alias Operator.Core.Usage
  alias Operator.Core.Usage.Fetch
  alias Operator.TermUI, as: UI
  alias Operator.Toggle

  @stale_s 300
  @bar 10

  def mount(params, _session, socket) do
    dir = Map.get(params, :data_dir) || Operator.Paths.data_dir()
    signed_in = Map.get_lazy(params, :signed_in, &signed_in/0)
    :ok = Usage.subscribe()

    socket =
      socket
      |> Mob.Socket.assign(
        data_dir: dir,
        model: params[:model],
        path: params[:path],
        signed_in: signed_in,
        refresh: Map.get(params, :refresh, &Fetch.refresh/2),
        fetching: %{}
      )
      |> load()

    now = socket.assigns.now

    stale =
      Enum.filter(signed_in, fn p ->
        at = (Usage.limits(socket.assigns.state, p) || %{})["checked_at"]
        not is_integer(at) or now - at > @stale_s
      end)

    {:ok, refresh(socket, stale)}
  end

  def render(a) do
    t = Term.theme()

    rows =
      Enum.flat_map(Auth.providers(), &provider_rows(&1, a, t)) ++
        [UI.actions(t, [UI.link("refresh", :refresh, t)])] ++
        tokens_rows(a, t) ++ model_rows(a, t)

    UI.page(t, "menu › usage", rows)
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info({:tap, :operator_toggle}, socket), do: {:noreply, Toggle.to_front(socket)}

  def handle_info({:link, %{url: link}}, socket) when is_binary(link),
    do: {:noreply, Mob.Socket.reset_to(socket, Operator.ChatScreen, %{link: link})}

  def handle_info({:tap, :refresh}, socket),
    do: {:noreply, refresh(socket, socket.assigns.signed_in)}

  def handle_info({:operator_usage, :changed}, socket), do: {:noreply, load(socket)}

  def handle_info({:operator_usage, provider, result}, socket) do
    note = with {:error, message} <- result, do: "usage endpoint: #{message}"
    note = if note == :ok, do: nil, else: note
    fetching = Map.put(socket.assigns.fetching, provider, note)
    {:noreply, socket |> Mob.Socket.assign(:fetching, fetching) |> load()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The endpoints answer off the screen process; each result comes back as
  # `{:operator_usage, provider, result}`.
  defp refresh(socket, providers) do
    screen = self()
    %{data_dir: dir, refresh: fun} = socket.assigns

    for p <- providers do
      {:ok, _} = Task.start(fn -> send(screen, {:operator_usage, p, run(fun, dir, p)}) end)
    end

    fetching = Map.merge(socket.assigns.fetching, Map.new(providers, &{&1, :fetching}))
    Mob.Socket.assign(socket, :fetching, fetching)
  end

  # A refresh that raises (an unwritable data dir, an odd reply) still answers.
  defp run(fun, dir, provider) do
    fun.(dir, provider)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, Exception.format_exit(reason)}
  end

  defp load(socket) do
    a = socket.assigns

    session =
      with path when is_binary(path) <- a.path,
           {:ok, _session, entries} <- Session.open(path, a.model || "") do
        Usage.session(entries)
      else
        _ -> nil
      end

    Mob.Socket.assign(socket,
      state: Usage.load(a.data_dir),
      session: session,
      now: System.os_time(:second),
      today: Budget.today()
    )
  end

  defp signed_in do
    if Process.whereis(Auth), do: for({p, %{signed_in: true}} <- Auth.status(), do: p), else: []
  end

  # ── subscription windows ──

  defp provider_rows(provider, a, t) do
    windows = Usage.windows(a.state, provider)
    limits = Usage.limits(a.state, provider)

    body =
      cond do
        windows != [] ->
          Enum.flat_map(windows, &window_rows(&1, a.now, t)) ++ [source_line(limits, a.now, t)]

        provider in a.signed_in ->
          [UI.line("no numbers yet: make a model call, or refresh", t, "dim")]

        true ->
          [UI.line("not signed in", t, "dim")]
      end

    [UI.heading(Auth.label(provider), t)] ++
      body ++
      limited_rows(Usage.rate_limited(a.state, provider), a.now, t) ++
      fetch_rows(a.fetching[provider], t)
  end

  defp window_rows({_id, w}, now, t) do
    pct = Usage.percent(w, now)
    filled = min(div(pct * @bar + 50, 100), @bar)
    bar = "[" <> String.duplicate("#", filled) <> String.duplicate(".", @bar - filled) <> "]"

    color =
      cond do
        pct >= 100 -> "error"
        pct >= 90 -> "notice"
        true -> "fg"
      end

    [
      UI.line("#{String.pad_trailing(w["label"], 8)} #{bar} #{pct}%", t, color),
      UI.line(reset_text(w["resets_at"], now), t, "dim")
    ]
  end

  defp reset_text(at, now) when is_integer(at) and at > now,
    do: "resets in #{Usage.duration(at - now)}"

  defp reset_text(at, now) when is_integer(at), do: "reset #{Usage.duration(now - at)} ago"
  defp reset_text(_at, _now), do: "reset time unknown"

  defp source_line(limits, now, t) do
    source = if limits["source"] == "endpoint", do: "usage endpoint", else: "last call's headers"
    plan = if limits["plan"], do: "plan #{limits["plan"]} · ", else: ""
    UI.line("#{plan}from the #{source}, #{ago(limits["checked_at"], now)}", t, "dim")
  end

  defp limited_rows(nil, _now, _t), do: []

  defp limited_rows(r, now, t) do
    reset =
      case r["resets_at"] do
        at when is_integer(at) and at > now -> "resets in #{Usage.duration(at - now)}"
        at when is_integer(at) -> "reset #{Usage.duration(now - at)} ago"
        _ -> "reset time not given"
      end

    color = if is_integer(r["resets_at"]) and r["resets_at"] > now, do: "error", else: "dim"
    model = r["model"] |> to_string() |> short_model()

    message =
      if r["message"] in [nil, ""], do: [], else: [UI.line(r["message"], t, "dim", max_lines: 3)]

    [UI.line("last 429 #{ago(r["at"], now)} (#{model}): #{reset}", t, color) | message]
  end

  defp fetch_rows(:fetching, t), do: [UI.line("asking the usage endpoint…", t, "dim")]
  defp fetch_rows(note, t) when is_binary(note), do: [UI.line(note, t, "notice")]
  defp fetch_rows(_note, _t), do: []

  # ── tokens and cost ──

  defp tokens_rows(a, t) do
    periods = [
      {"session", a.session},
      {"today", Usage.sum(Usage.by_model(a.state, a.today))},
      {"all time", Usage.sum(Usage.by_model(a.state, :total))}
    ]

    [UI.heading("tokens and cost", t)] ++
      Enum.flat_map(periods, fn
        {label, nil} ->
          [UI.line("#{String.pad_trailing(label, 9)} no session file yet", t, "dim")]

        {label, c} ->
          counter_rows(String.pad_trailing(label, 9), c, t)
      end)
  end

  defp model_rows(a, t) do
    models =
      a.state
      |> Usage.by_model(:total)
      |> Enum.sort_by(fn {model, c} -> {-c["cost"], model} end)

    body =
      if models == [],
        do: [UI.line("no model calls recorded yet", t, "dim")],
        else: Enum.flat_map(models, fn {model, c} -> counter_rows(short_model(model), c, t) end)

    [UI.heading("by model, all time", t) | body]
  end

  defp counter_rows(label, c, t) do
    errors = if c["errors"] > 0, do: " · #{c["errors"]} failed", else: ""
    cost = :erlang.float_to_binary(c["cost"] * 1.0, decimals: 4)

    [
      UI.line("#{label} #{c["requests"]} req#{errors} · $#{cost}", t),
      UI.line(
        "in #{k(c["input"])} · out #{k(c["output"])} · cache #{k(c["cacheRead"])} read, " <>
          "#{k(c["cacheWrite"])} write",
        t,
        "dim"
      )
    ]
  end

  defp k(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp k(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp k(n), do: "#{n}"

  defp ago(at, now) when is_integer(at), do: "#{Usage.duration(max(now - at, 0))} ago"
  defp ago(_at, _now), do: "at an unknown time"

  defp short_model(model), do: model |> String.split(["/", ":"]) |> List.last()
end
