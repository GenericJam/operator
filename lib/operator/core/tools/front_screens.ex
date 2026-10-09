defmodule Operator.Core.Tools.FrontScreens do
  @moduledoc """
  Core tool: the front's screens (`Operator.Core.Front`), which one is open
  and whether it crashed. Acts on `ctx[:front]` if given (tests).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front

  @impl true
  def name, do: "front_screens"

  @impl true
  def description,
    do:
      "List the front's screens (the app's UI, which the user switches to with the toggle in " <>
        "the upper left corner): their names (for front_open and the Operator.Dyn module " <>
        "names below which their sources live), the screen that is open and the ones under it, " <>
        "and the open screen's crash, if it crashed."

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 15_000

  @impl true
  def run(_args, ctx) do
    front = Map.get(ctx, :front, Front)
    names = Front.screens(front)
    status = Front.status(front)

    if names == [] do
      {:ok, "There are no front screens yet. " <> view(status.view)}
    else
      {:ok,
       Enum.join(
         [
           "Open: " <>
             open(status.stack) <>
             " (" <> where(status.visible) <> gen(status[:generation]) <> ")",
           view(status.view),
           "#{length(names)} front screens:",
           Enum.join(names, "\n")
         ],
         "\n"
       )}
    end
  end

  defp open([]), do: "none yet (the front opens its start screen when it's next shown)"
  defp open([top]), do: top
  defp open([top | under]), do: "#{top}, over #{Enum.join(under, ", ")}"

  defp where(true), do: "the front is on screen"
  defp where(false), do: "the user is in the terminal"

  defp gen(nil), do: ""
  defp gen(n), do: ", generation G#{n}"

  defp view(:running), do: "It runs."
  defp view({:note, note}), do: note
  defp view({:error, text}), do: "It crashed:\n" <> text
end
