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
  Stick-to-bottom for the transcript list. Before each repaint the screen
  asks where the list is: at (or near) the bottom means keep following new
  output; scrolled up means the user is reading, so leave it alone until
  they come back down. Android's lazy list reports item indexes (`:index`),
  iOS a pixel scroll view (`:pixel`).
  """

  @doc "Whether to keep following, given the list's scroll info (or an error: keep the current choice)."
  @spec following?(map() | {:error, term()} | nil, boolean()) :: boolean()
  def following?(%{} = info, _current), do: at_bottom?(info)
  def following?(_unavailable, current), do: current

  @spec at_bottom?(map()) :: boolean()
  def at_bottom?(%{kind: :index, offset: {_, y}, max_offset: {_, max}}), do: max - y <= 1.0

  def at_bottom?(%{kind: :pixel, offset: {_, y}, max_offset: {_, max}, viewport: {_, vh}}),
    do: max - y <= max(vh * 0.15, 32.0)

  @doc "Where `scroll_to/3` should go to show the end: the last item (index lists clamp) or the max offset."
  @spec bottom(map()) :: {float(), float()}
  def bottom(%{kind: :index, content: {_, items}}), do: {0.0, max(items - 1.0, 0.0)}
  def bottom(%{kind: :pixel, max_offset: {_, max}}), do: {0.0, max}
end
