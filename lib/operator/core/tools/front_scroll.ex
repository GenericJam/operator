defmodule Operator.Core.Tools.FrontScroll do
  @moduledoc """
  Core tool: scrolls a scroll view on the open front screen and returns a
  screenshot of the result, so the agent can see what is below the fold.
  Scrolling and the shot are one call because a scroll position only exists
  while the front is on screen: if the user is in the terminal, the front
  shows for the moment (`Operator.Core.Tools.FrontScreenshot.capture/2`).

  A scroll view is found by its `id` prop (mob's `scroll_info`/`scroll_to`
  NIFs, as `Mob.Test.scroll_to/4` drives them); without one given, the
  open screen's only scroll view with an id. Offsets are the native
  view's units: device pixels, or items for a lazy list.

  `ctx[:front]` replaces the front, `ctx[:scroll_nif]` the NIF module
  (`scroll_info/1`, `scroll_to/3`), `ctx[:front_show]` the
  show-and-capture (tests have no screen), `ctx[:foreground?]`
  `Front.app_foreground?/0` (the cover warning, as `front_screenshot`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front
  alias Operator.Core.Tools.FrontScreenshot
  alias Operator.Core.Tools.FrontTap

  # A scroll animates; the shot waits for it.
  @settle_ms 400

  @impl true
  def name, do: "front_scroll"

  @impl true
  def description,
    do:
      "Scroll a scroll view on the open front screen and see the result (returns a " <>
        "screenshot): to look below the fold. `to`: top, bottom, down (one screenful), up, " <>
        "or a page number (\"2\"; page 1 is the top). `id`: the scroll view's id prop; " <>
        "optional when the screen has one scroll view with an id. A scroll view needs an " <>
        "`id` prop (`type: :scroll, props: %{id: :page}`) to be scrolled."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{
          "type" => "string",
          "description" => "top, bottom, down, up, or a page number such as \"2\"."
        },
        "id" => %{"type" => "string", "description" => "The scroll view's id prop."}
      },
      "required" => ["to"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 20_000

  @impl true
  def run(%{"to" => to} = args, ctx) when is_binary(to) do
    front = Map.get(ctx, :front, Front)
    nif = Map.get(ctx, :scroll_nif, :mob_nif)
    show = Map.get(ctx, :front_show, &FrontScreenshot.capture/2)

    with {:ok, target} <- target(to),
         {:ok, id} <- scroll_id(args["id"], front),
         {:ok, text, jpeg} <- show.(front, fn -> scroll(nif, id, target) end) do
      {:ok, text} = FrontTap.covered({:ok, text}, ctx)
      {:ok, {:image, "image/jpeg", jpeg, text}}
    end
  end

  def run(_args, _ctx), do: {:error, "`to` is required: top, bottom, down, up or a page number"}

  @doc false
  # "top" | "bottom" | "down" | "up" | a page number, 1 the top.
  @spec target(String.t()) :: {:ok, atom() | {:page, pos_integer()}} | {:error, String.t()}
  def target(to) do
    case String.downcase(String.trim(to)) do
      word when word in ["top", "bottom", "down", "up"] ->
        {:ok, String.to_existing_atom(word)}

      other ->
        case Integer.parse(other) do
          {n, ""} when n >= 1 -> {:ok, {:page, n}}
          _ -> {:error, "`to` must be top, bottom, down, up or a page number (1 is the top)"}
        end
    end
  end

  defp scroll_id(id, _front) when is_binary(id) and id != "", do: {:ok, id}

  defp scroll_id(_none, front) do
    case Front.scroll_views(front) do
      {:error, :not_running} ->
        {:error, "No front screen is running: open one with front_open first."}

      {:ok, []} ->
        {:error, "The open front screen has no scroll view (`type: :scroll`)."}

      {:ok, views} ->
        case Enum.filter(views, & &1.id) do
          [] ->
            {:error,
             "The open front screen's scroll view has no `id`, so it can't be scrolled: give " <>
               "it one (`type: :scroll, props: %{id: :page, ...}`, or `id` on <Scroll>) and " <>
               "propose the change."}

          [one] ->
            {:ok, to_string(one.id)}

          many ->
            listed = Enum.map_join(many, "\n", &"- #{&1.id}#{about(&1.text)}")
            {:error, "The open front screen has several scroll views; give `id`:\n" <> listed}
        end
    end
  end

  defp about(""), do: ""
  defp about(text), do: " (" <> text <> ")"

  # Runs with the front on screen.
  defp scroll(nif, id, target) do
    with {:ok, before} <- info(nif, id),
         {x, y} = resolve(target, before),
         :ok <- scroll_to(nif, id, x, y),
         Process.sleep(@settle_ms),
         {:ok, now} <- info(nif, id) do
      {:ok, describe(id, target, before, now)}
    end
  end

  defp info(nif, id) do
    case nif.scroll_info(id) do
      json when is_binary(json) ->
        case JSON.decode(json) do
          {:ok, %{} = m} -> {:ok, decode(m)}
          _ -> {:error, "the scroll view #{id} answered #{String.slice(json, 0, 100)}"}
        end

      other ->
        not_found(id, other)
    end
  rescue
    e in [UndefinedFunctionError, ErlangError] -> no_native(e)
  end

  defp scroll_to(nif, id, x, y) do
    case nif.scroll_to(id, x * 1.0, y * 1.0) do
      :ok -> :ok
      other -> not_found(id, other)
    end
  rescue
    e in [UndefinedFunctionError, ErlangError] -> no_native(e)
  end

  defp not_found(id, {:error, :scroll_view_not_found}),
    do:
      {:error,
       "No scroll view with id #{id} is on screen (a typo, or the screen draws it " <>
         "differently now: front_state and front_screenshot show what it is doing)."}

  defp not_found(id, other), do: {:error, "scrolling #{id} failed: #{inspect(other, limit: 5)}"}

  defp no_native(e),
    do: {:error, "scrolling needs the phone's native UI: #{Exception.message(e)}"}

  defp decode(m) do
    %{
      y: num(m["offset_y"]),
      x: num(m["offset_x"]),
      max_y: num(m["max_y"]),
      max_x: num(m["max_x"]),
      viewport: num(m["viewport_h"]),
      content: num(m["content_h"]),
      unit: if(m["kind"] == "index", do: "items", else: "px")
    }
  end

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: 0.0

  @doc false
  # The absolute offset for `target`, clamped to the view's extent.
  @spec resolve(atom() | {:page, pos_integer()}, map()) :: {float(), float()}
  def resolve(target, %{x: x, y: y, max_y: max_y, viewport: vh}) do
    to =
      case target do
        :top -> 0.0
        :bottom -> max_y
        :down -> y + vh
        :up -> y - vh
        {:page, n} -> (n - 1) * vh
      end

    {x, to |> max(0.0) |> min(max_y)}
  end

  @doc false
  @spec describe(String.t(), term(), map(), map()) :: String.t()
  def describe(id, target, before, now) do
    {page, pages} = page(now)

    "Scrolled #{id}: page #{page} of #{pages}, offset #{round(now.y)} of " <>
      "#{round(now.max_y)} #{now.unit} (content #{round(now.content)}, screenful " <>
      "#{round(now.viewport)}).#{stuck(target, before, now)} Screenshot of the front:"
  end

  # {page shown, pages}: the last page at the bottom, 1 the top.
  defp page(%{viewport: vh} = now) when vh > 0 do
    pages = max(1, ceil(now.content / vh))

    if now.y >= now.max_y and now.max_y > 0,
      do: {pages, pages},
      else: {min(pages, trunc(now.y / vh) + 1), pages}
  end

  defp page(_now), do: {1, 1}

  defp stuck(_target, %{y: y}, %{y: now_y}) when y != now_y, do: ""

  defp stuck(_target, _before, %{max_y: max_y}) when max_y == 0,
    do: " Everything fits: there is nothing to scroll."

  defp stuck(target, _before, now) do
    cond do
      target in [:down, :bottom] and now.y >= now.max_y -> " It was already at the bottom."
      target in [:up, :top] and now.y <= 0 -> " It was already at the top."
      true -> " It didn't move."
    end
  end

  @impl true
  def selftest do
    info = %{x: 0.0, y: 0.0, max_y: 1000.0, viewport: 600.0, content: 1600.0, unit: "px"}

    with {:ok, {:page, 2}} <- target(" 2 "),
         {:error, _} <- target("sideways"),
         {+0.0, 600.0} <- resolve(:down, info),
         {+0.0, 1000.0} <- resolve({:page, 9}, info),
         {+0.0, +0.0} <- resolve(:up, info) do
      :ok
    else
      other -> {:error, other}
    end
  end
end
