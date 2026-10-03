defmodule Operator.Core.Voice do
  @moduledoc """
  Reads short updates aloud from the loops' events (PLAN.md "Background
  processing"), so a backgrounded run can be followed by ear. What is said
  follows `Operator.Core.Settings.voice/0`:

    * `:important` (default): when a run ends: finished (the first sentence
      of the final reply, at most ~200 chars, markup stripped), stopped,
      error (short) or step limit; when a self-change waits for approval
      or was reverted (`Operator.Core.Dyn` events).
    * `:everything`: also each complete assistant reply (markup stripped);
      a finished run whose final reply was read adds nothing.
    * `:off`: nothing.

  The platforms don't report when an utterance ends, so the time it takes
  is estimated from its length (`:pace`). While one is playing, a reply is
  skipped, and a run-end line interrupts it (stop, then speak).

  ## Speech outside a screen

  `Mob.Speech.speak/3` takes a socket but never uses it: it is
  `:mob_nif.tts_speak(text, opts_json)` (and `stop_speaking/1` is
  `:mob_nif.tts_stop/0`), fire-and-forget NIFs callable from any process.
  On Android the NIF calls the host's `MobBridge.ttsSpeak`, which needs the
  Activity (`activityRef`) and runs on its UI thread: it works while the
  app is backgrounded as long as the Activity exists, and does nothing if
  it was destroyed. iOS uses `AVSpeechSynthesizer` on the main queue.

  A separate process watching every loop `Operator.Core.Current` starts
  (`Operator.Core.Watcher`); a failing backend is logged, never raised.

  Options: `:backend` (`{module, arg}`, `Operator.Core.Voice.Speech`;
  default `{Operator.Core.Voice.MobSpeech, []}`), `:setting` (0-arity fun
  returning the voice setting; default `&Operator.Core.Settings.voice/0`),
  `:pace` (`{base_ms, ms_per_char}`, default `{500, 75}`), `:current`,
  `:keeper` (whose Dyn events to follow), `:name`.
  """
  use GenServer

  alias Operator.Core.Dyn
  alias Operator.Core.Session
  alias Operator.Core.Watcher

  require Logger

  @defaults [
    backend: {Operator.Core.Voice.MobSpeech, []},
    setting: &Operator.Core.Settings.voice/0,
    pace: {500, 75},
    current: Operator.Core.Current,
    keeper: Operator.Core.Dyn.Keeper
  ]

  @summary_chars 200
  @error_chars 120
  @reply_chars 1_500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      backend: opts[:backend],
      setting: opts[:setting],
      pace: opts[:pace],
      watch: Watcher.new(opts[:current]),
      runs: %{},
      busy_until: nil
    }

    _ = Dyn.subscribe(opts[:keeper])
    {:ok, state, {:continue, :watch}}
  end

  @impl true
  def handle_continue(:watch, s), do: {:noreply, %{s | watch: Watcher.watch(s.watch)}}

  @impl true
  def handle_info({:operator_core, sid, event}, s), do: {:noreply, event(s, sid, event)}

  def handle_info({:operator_dyn, event}, s) do
    case {setting(s), dyn_line(event)} do
      {:off, _} -> {:noreply, s}
      {_, nil} -> {:noreply, s}
      {_, text} -> {:noreply, say(s, text, :important)}
    end
  end

  def handle_info(message, s) do
    case Watcher.handle(message, s.watch) do
      {:loop_down, sid, w} ->
        runs = if Watcher.session?(w, sid), do: s.runs, else: Map.delete(s.runs, sid)
        {:noreply, %{s | watch: w, runs: runs}}

      {:loop_up, _sid, w} ->
        {:noreply, %{s | watch: w}}

      {:ok, w} ->
        {:noreply, %{s | watch: w}}

      :ignore ->
        {:noreply, s}
    end
  end

  # ── events ──

  defp event(s, sid, %{type: :agent_start}), do: put_in(s.runs[sid], %{reply: nil, error: nil})

  defp event(s, sid, %{type: :message_end, entry: %{"message" => %{"role" => "assistant"} = m}}) do
    text = Session.text(m["content"])

    if String.trim(text) == "" or m["stopReason"] in ["error", "aborted"] do
      s
    else
      s = update_run(s, sid, &%{&1 | reply: text})
      if setting(s) == :everything, do: say(s, cap(plain(text), @reply_chars), :reply), else: s
    end
  end

  defp event(s, sid, %{type: :turn_end, error: error}) when is_binary(error),
    do: update_run(s, sid, &%{&1 | error: error})

  defp event(s, sid, %{type: :agent_end, reason: reason}) do
    {run, runs} = Map.pop(s.runs, sid, %{reply: nil, error: nil})
    s = %{s | runs: runs}

    case line(setting(s), reason, run) do
      nil -> s
      text -> say(s, text, :important)
    end
  end

  defp event(s, _sid, _event), do: s

  @doc "What is said for a self-modification event, or nil."
  @spec dyn_line(map()) :: String.t() | nil
  def dyn_line(%{type: :candidate, gen: n}),
    do: "A change to Operator, generation #{n}, needs your approval."

  def dyn_line(%{type: :reverted, from: from}),
    do: "Generation #{from} kept crashing and was reverted."

  def dyn_line(%{type: :safe_mode}), do: "Operator started in safe mode."
  def dyn_line(_event), do: nil

  defp update_run(s, sid, fun),
    do: %{s | runs: Map.update(s.runs, sid, fun.(%{reply: nil, error: nil}), fun)}

  @doc """
  What is said when a run ends with `reason` under `setting`, or nil.
  `run` holds the run's last assistant reply and last error.
  """
  @spec line(Operator.Core.Settings.voice(), atom(), %{reply: String.t() | nil, error: term()}) ::
          String.t() | nil
  def line(:off, _reason, _run), do: nil
  def line(:everything, :done, %{reply: reply}) when is_binary(reply), do: nil

  def line(_setting, :done, %{reply: reply}) when is_binary(reply) do
    case summary(reply) do
      "" -> "Done."
      text -> text
    end
  end

  def line(_setting, :done, _run), do: "Done."
  def line(_setting, :stopped, _run), do: "Stopped."
  def line(_setting, :max_iterations, _run), do: "Stopped: too many steps in one run."
  def line(_setting, :cost_cap, _run), do: "Stopped: the daily cost cap is reached."

  def line(_setting, :error, %{error: error}) when is_binary(error) do
    case error |> plain() |> first_sentence() |> cap(@error_chars) do
      "" -> "The run failed."
      text -> "Error: " <> text
    end
  end

  def line(_setting, :error, _run), do: "The run failed."
  def line(_setting, _reason, _run), do: nil

  # ── speaking ──

  defp say(s, text, priority) do
    now = System.monotonic_time(:millisecond)
    busy = s.busy_until != nil and now < s.busy_until

    cond do
      text == "" ->
        s

      busy and priority != :important ->
        s

      true ->
        if busy, do: call(s, :stop, [])

        if call(s, :speak, [text]),
          do: %{s | busy_until: now + duration(s.pace, text)},
          else: s
    end
  end

  defp duration({base_ms, ms_per_char}, text), do: base_ms + ms_per_char * String.length(text)

  defp setting(s), do: s.setting.()

  # true when the call succeeded; see Operator.Core.KeepAlive for why a
  # failing backend is logged and not raised.
  defp call(%{backend: {mod, arg}}, fun, args) do
    case apply(mod, fun, [arg | args]) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("[voice] #{fun} failed: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Logger.warning("[voice] #{fun} raised: #{Exception.message(e)}")
      false
  end

  # ── text ──

  @doc """
  The first sentence of `markdown` as plain text, at most
  #{@summary_chars} characters (cut at a word, with an ellipsis).
  """
  @spec summary(String.t()) :: String.t()
  def summary(markdown), do: markdown |> plain() |> first_sentence() |> cap(@summary_chars)

  @doc """
  `markdown` as text to read aloud: code blocks, display math, URLs and
  HTML tags dropped; links and images become their text; heading, quote,
  list and table markers and emphasis removed; lines joined into sentences.
  """
  @spec plain(String.t()) :: String.t()
  def plain(markdown) do
    markdown
    |> String.replace(~r/^ {0,3}(```|~~~).*?(^ {0,3}\1[^\n]*$|\z)/ms, "\n")
    |> String.replace(~r/\$\$.*?\$\$/s, " ")
    |> String.split("\n")
    |> Enum.map(&plain_line/1)
    |> Enum.reject(&(&1 == ""))
    |> join_lines()
  end

  defp plain_line(line) do
    if Regex.match?(~r/^\s*(([-*_]\s*){3,}|\|?[\s:|-]*-[\s:|-]*)$/, line) do
      ""
    else
      line
      |> String.replace(~r/^\s{0,3}(\#{1,6}\s+|>\s?)+/, "")
      |> String.replace(~r/^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, "")
      |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
      |> String.replace(~r/<https?:[^>]*>|https?:\/\/\S+/, "")
      |> String.replace(~r/<\/?[a-zA-Z][^>]*>/, "")
      |> String.replace(~r/\*\*|__|~~|`/, "")
      |> String.replace(~r/\$([^$\s][^$]*?)\$/, "\\1")
      |> String.replace(~r/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/, "\\1")
      |> String.replace(~r/(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)/, "\\1")
      |> String.trim()
      |> String.trim("|")
      |> String.replace(~r/\s*\|\s*/, ", ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end
  end

  # A line without closing punctuation (a heading, a list item) ends a sentence.
  defp join_lines(lines) do
    Enum.map_join(lines, " ", fn line ->
      if Regex.match?(~r/[.!?:;,]$/, line), do: line, else: line <> "."
    end)
  end

  defp first_sentence(text) do
    case Regex.run(~r/^.*?[.!?](?=\s|$)/s, text) do
      [sentence] -> sentence
      nil -> text
    end
  end

  defp cap(text, max) do
    if String.length(text) <= max do
      text
    else
      cut = String.slice(text, 0, max - 1)
      cut = Regex.replace(~r/\s+\S*$/, cut, "")
      String.trim_trailing(cut, ",;:") <> "…"
    end
  end
end

defmodule Operator.Core.Voice.Speech do
  @moduledoc "How `Operator.Core.Voice` speaks. `arg` is the backend's own."

  @callback speak(arg :: term(), text :: String.t()) :: :ok | {:error, term()}
  @callback stop(arg :: term()) :: :ok | {:error, term()}
end

defmodule Operator.Core.Voice.MobSpeech do
  @moduledoc """
  The platform's text-to-speech through mob's NIF (what `Mob.Speech` calls;
  see `Operator.Core.Voice`). On the host the NIF isn't loaded, so the calls
  return `{:error, :unavailable}`.
  """
  @behaviour Operator.Core.Voice.Speech

  @impl true
  def speak(_arg, text), do: nif(fn -> :mob_nif.tts_speak(text, "{}") end)

  @impl true
  def stop(_arg), do: nif(&:mob_nif.tts_stop/0)

  defp nif(fun) do
    case fun.() do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end
end
