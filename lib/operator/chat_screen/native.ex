defmodule Operator.ChatScreen.Native do
  @moduledoc """
  The chat screen's calls into the native layer (clipboard, scroll position).
  Swappable through `config :operator, :chat_native, Module` so host tests
  run without the NIF; on the host the NIF isn't loaded and these return
  `{:error, :unavailable}` instead of raising.
  """

  @callback clipboard_put(String.t()) :: :ok | {:error, term()}
  @callback scroll_info(String.t()) :: map() | {:error, term()}
  @callback scroll_to(String.t(), float(), float()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  @spec impl() :: module()
  def impl, do: Application.get_env(:operator, :chat_native, __MODULE__)

  @impl true
  def clipboard_put(text) do
    _ = :mob_nif.clipboard_put(text)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def scroll_info(id) do
    case :mob_nif.scroll_info(id) do
      json when is_binary(json) -> decode(json)
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def scroll_to(id, x, y) do
    case :mob_nif.scroll_to(id, x * 1.0, y * 1.0) do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  # Same shape as Mob.Test.scroll_info/2.
  defp decode(json) do
    m = Jason.decode!(json)

    %{
      offset: {f(m["offset_x"]), f(m["offset_y"])},
      content: {f(m["content_w"]), f(m["content_h"])},
      viewport: {f(m["viewport_w"]), f(m["viewport_h"])},
      max_offset: {f(m["max_x"]), f(m["max_y"])},
      kind: if(m["kind"] == "index", do: :index, else: :pixel)
    }
  end

  defp f(n) when is_number(n), do: n * 1.0
  defp f(_), do: 0.0
end

defmodule Operator.ChatScreen.Follow do
  @moduledoc """
  Stick-to-bottom for the transcript list, decided from how the list
  moved, not from where it is relative to a max that new rows just grew:
  a burst of rows leaves the offset far from the new bottom even though
  the user never scrolled.

    * Following, and the offset didn't go back since the last check: keep
      following (the list only moves down by our own scrolling).
    * Following, and the offset went back: the user scrolled up; stop.
    * Not following: resume once the user is back at the bottom.

  Android's lazy list reports item indexes (`:index`), iOS a pixel scroll
  view (`:pixel`).
  """

  @doc """
  `{following, offset_to_remember}` from the list's scroll info, whether we
  were following, and the offset seen at the last check (nil at first).
  Without scroll info (host, list not laid out yet) nothing changes.
  """
  @spec decide(map() | {:error, term()} | nil, boolean(), float() | nil) ::
          {boolean(), float() | nil}
  def decide(%{offset: {_, y}} = info, true, last),
    do: {last == nil or y >= last - slack(info), y}

  def decide(%{offset: {_, y}} = info, false, _last), do: {at_bottom?(info), y}
  def decide(_unavailable, following, last), do: {following, last}

  # How far back the offset may move without counting as a user scroll.
  defp slack(%{kind: :index}), do: 0.5
  defp slack(%{kind: :pixel}), do: 4.0

  @spec at_bottom?(map()) :: boolean()
  def at_bottom?(%{kind: :index, offset: {_, y}, max_offset: {_, max}}), do: max - y <= 1.0

  def at_bottom?(%{kind: :pixel, offset: {_, y}, max_offset: {_, max}, viewport: {_, vh}}),
    do: max - y <= max(vh * 0.15, 32.0)

  @doc "Where `scroll_to/3` should go to show the end: the last item (index lists clamp) or the max offset."
  @spec bottom(map()) :: {float(), float()}
  def bottom(%{kind: :index, content: {_, items}}), do: {0.0, max(items - 1.0, 0.0)}
  def bottom(%{kind: :pixel, max_offset: {_, max}}), do: {0.0, max}
end
