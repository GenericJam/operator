defmodule Operator.Core.Tools.FrontScreenshot do
  @moduledoc """
  Core tool: a screenshot of the front, for the model to see (an image in
  the tool result, `Operator.Core.ToolRunner`). If the user is in the
  terminal, the front is put on screen for the shot (the shell pushed over
  the terminal, as the toggle does) and taken away again, so they see it
  flash by. Acts on `ctx[:front]` if given; `ctx[:front_capture]`
  replaces the capture itself (a `(front -> {:ok, jpeg} | {:error, text})`;
  tests have no screen).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front

  # The view arrives from the front's process, then native lays it out.
  @show_wait_ms 3_000
  @settle_ms 700
  @scale 0.75
  @quality 70

  @impl true
  def name, do: "front_screenshot"

  @impl true
  def description,
    do:
      "Take a screenshot of the front (the app's UI, under the toggle) and look at it: to " <>
        "check a front screen you built or changed, or what the user is looking at. If the " <>
        "user is in the terminal, the front shows for a moment while it's taken."

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 20_000

  @impl true
  def run(_args, ctx) do
    front = Map.get(ctx, :front, Front)
    capture = Map.get(ctx, :front_capture, &capture/1)

    with {:ok, jpeg} <- capture.(front) do
      status = Front.status(front)
      open = List.first(status.stack) || "the start screen"
      {:ok, {:image, "image/jpeg", jpeg, "Screenshot of the front, showing #{open}."}}
    end
  end

  defp capture(front) do
    if Front.status(front).visible do
      shot()
    else
      :ok = Front.navigate({:push, Operator.ShellScreen, %{}})

      try do
        wait_visible(front, System.monotonic_time(:millisecond) + @show_wait_ms)
        Process.sleep(@settle_ms)
        shot()
      after
        # Back to the terminal, unless the user left the front already.
        if GenServer.call(:mob_screen, :get_current_module) == Operator.ShellScreen,
          do: Front.navigate({:pop})
      end
    end
  end

  # Shown, and past the blank view a new host draws until its first paint.
  defp wait_visible(front, deadline) do
    cond do
      match?(%{visible: true, view: view} when view != {:note, ""}, Front.status(front)) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :ok

      true ->
        Process.sleep(100)
        wait_visible(front, deadline)
    end
  end

  defp shot do
    case :mob_nif.screenshot(:jpeg, @quality, @scale) do
      bytes when is_binary(bytes) -> {:ok, bytes}
      other -> {:error, "the screenshot failed: #{inspect(other)}"}
    end
  end
end
