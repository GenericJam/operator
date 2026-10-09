defmodule Operator.Core.Tools.FrontTap do
  @moduledoc """
  Core tool: taps a button (anything with `on_tap`) on the open front screen
  by its tag (`Operator.Core.Front.tap/2`), so the agent can try the screens
  it builds: tap, then `front_screenshot`. Acts on `ctx[:front]` if given.
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
        "screen doesn't have, it lists the tags it has. Use front_screenshot to see the result."

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
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"tag" => tag}, ctx) when is_binary(tag) do
    case Front.tap(tag, Map.get(ctx, :front, Front)) do
      {:ok, screen} ->
        {:ok, "Tapped #{tag} on #{screen}."}

      {:error, :not_running} ->
        {:error, "No front screen is running: open one with front_open first."}

      {:error, {:unknown_tag, []}} ->
        {:error, "The open front screen has nothing tappable."}

      {:error, {:unknown_tag, taps}} ->
        listed = Enum.map_join(taps, "\n", fn {t, text} -> "- #{t}#{about(text)}" end)
        {:error, "The open front screen has no tag #{tag}. Its tappable tags:\n" <> listed}
    end
  end

  def run(_args, _ctx), do: {:error, "`tag` is required"}

  defp about(""), do: ""
  defp about(text), do: " (" <> String.slice(text, 0, 60) <> ")"

  @impl true
  def selftest do
    with {:error, "`tag` is required"} <- run(%{}, %{}), do: :ok
  end
end
