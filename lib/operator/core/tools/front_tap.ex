defmodule Operator.Core.Tools.FrontTap do
  @moduledoc """
  Core tool: taps a button (anything with `on_tap`) on the open front screen
  by its tag (`Operator.Core.Front.tap/3`), so the agent can try the screens
  it builds: tap, then `front_screenshot`. It says whether the screen drew a
  new view within a second, so a tap that went nowhere (a screen that
  hasn't handled it yet, after a restart, say) doesn't pass for one that
  worked. While another app's window covers Operator (`Front.cover_warning/1`)
  it says so too: the tap reached the screen, but the user's touches don't.
  Acts on `ctx[:front]` if given; `ctx[:foreground?]` replaces
  `Front.app_foreground?/0`.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front

  @impl true
  def name, do: "front_tap"

  @impl true
  def description,
    do:
      "Tap a button (anything with on_tap) on the open front screen, by its tag: " <>
        "on_tap={{self(), :roll}} has the tag `roll` (a tuple tag by how it prints, e.g. " <>
        "`{:pick, 2}`). The screen gets the same {:tap, tag} a finger sends. With a tag the " <>
        "screen doesn't have, it lists the tags it has. Says whether the screen re-rendered; " <>
        "use front_screenshot to see the result."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"tag" => %{"type" => "string", "minLength" => 1, "maxLength" => 200}},
      "required" => ["tag"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 10_000

  @impl true
  def run(%{"tag" => tag}, ctx) when is_binary(tag) do
    result =
      case Front.tap(tag, Map.get(ctx, :front, Front)) do
        {:ok, screen, outcome} ->
          outcome("Tapped #{tag} on #{screen}", outcome)

        {:error, :not_running} ->
          {:error, "No front screen is running: open one with front_open first."}

        {:error, {:unknown_tag, []}} ->
          {:error, "The open front screen has nothing tappable."}

        {:error, {:unknown_tag, taps}} ->
          listed = Enum.map_join(taps, "\n", fn {t, text} -> "- #{t}#{about(text)}" end)
          {:error, "The open front screen has no tag #{tag}. Its tappable tags:\n" <> listed}
      end

    covered(result, ctx)
  end

  def run(_args, _ctx), do: {:error, "`tag` is required"}

  @doc "The tool result for `done` (\"Tapped x on Home\") and what the screen did after it."
  @spec outcome(String.t(), Front.outcome()) :: {:ok, String.t()} | {:error, String.t()}
  def outcome(done, :rendered), do: {:ok, "#{done}; it re-rendered."}

  def outcome(done, :no_render),
    do:
      {:ok,
       "#{done}; the screen did not re-render within 1 s (it may not have handled it yet, " <>
         "or it changes nothing visible): take a front_screenshot."}

  def outcome(done, {:crashed, error}),
    do: {:error, "#{done}; the screen crashed:\n#{error}"}

  @doc """
  `result` (`{:ok, text}` or `{:error, text}`) with `Front.cover_warning/1`
  added on a line of its own while another app's window covers Operator.
  """
  @spec covered({:ok | :error, String.t()}, map()) :: {:ok | :error, String.t()}
  def covered({status, text} = result, ctx) when is_binary(text) do
    foreground? = Map.get(ctx, :foreground?, &Front.app_foreground?/0)

    case Front.cover_warning(foreground?.()) do
      nil -> result
      warning -> {status, text <> "\n\n" <> warning}
    end
  end

  defp about(""), do: ""
  defp about(text), do: " (" <> String.slice(text, 0, 60) <> ")"

  @impl true
  def selftest do
    with {:error, "`tag` is required"} <- run(%{}, %{}), do: :ok
  end
end
