defmodule Operator.Core.Tools.FrontOpen do
  @moduledoc """
  Core tool: switches the front to one of its screens (`Operator.Core.Front.open/2`),
  for when the user asks, or built a front with no way to a screen. Acts on
  `ctx[:front]` if given (tests).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front
  alias Operator.Core.Tools.FrontTap

  @impl true
  def name, do: "front_open"

  @impl true
  def description,
    do:
      "Switch the front (the app's UI the user reaches with the toggle) to one of its screens, " <>
        "by the name front_screens lists (or the last part of it, e.g. Slider). The front " <>
        "opens it from now on, also after a restart, until the user navigates away."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "screen" => %{
          "type" => "string",
          "description" => "The screen's name, from front_screens."
        }
      },
      "required" => ["screen"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 25_000

  # The front has one screen: no other front call runs alongside.
  @impl true
  def concurrency, do: :exclusive

  @impl true
  def run(args, ctx), do: FrontTap.exclusive(ctx, fn -> act(args, ctx) end)

  defp act(%{"screen" => screen}, ctx) when is_binary(screen) do
    case Front.open(screen, [], Map.get(ctx, :front, Front)) do
      {:ok, name} ->
        {:ok,
         "The front shows #{name} now; the user sees it when they switch to the front " <>
           "(front_screenshot shows it to you)."}

      {:error, :unknown_screen} ->
        {:error, "No front screen is called #{screen}; front_screens lists them."}

      {:error, {:ambiguous, names}} ->
        {:error, "#{screen} could be any of: #{Enum.join(names, ", ")}"}
    end
  end

  defp act(_args, _ctx), do: {:error, "screen (a front screen's name) is required"}
end
