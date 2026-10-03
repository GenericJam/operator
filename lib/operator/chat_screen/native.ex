defmodule Operator.ChatScreen.Native do
  @moduledoc """
  The chat screen's calls into the native layer (clipboard, scroll position).
  Swappable through `config :operator, :chat_native, Module` so host tests
  run without the NIF; on the host the NIF isn't loaded and these return
  `{:error, :unavailable}` instead of raising.
  """

  alias Operator.Core.Dyn.Approval.Biometric

  @callback clipboard_put(String.t()) :: :ok | {:error, term()}
  @callback scroll_info(String.t()) :: map() | {:error, term()}
  @callback scroll_to(String.t(), float(), float()) :: :ok | {:error, term()}
  @doc "Asks the OS for a permission; the answer comes as `{:permission, capability, result}`."
  @callback request_permission(atom()) :: :ok | {:error, term()}
  @doc "Shows the fingerprint prompt; the answer comes as `{:biometric, :success | :failure | :not_available}`."
  @callback authenticate(String.t()) :: :ok | {:error, term()}
  @doc "Records that the human just passed the fingerprint check for `subject` (`Dyn.Approval.Biometric`)."
  @callback confirm_approval(Operator.Core.Dyn.Approval.subject()) :: :ok | {:error, term()}
  @doc """
  Starts a phone action for a tool (`Operator.Core.Phone`); its result
  arrives as the plugin's message (`{:location, ...}`, `{:camera, ...}`,
  `{:photos, ...}`). `:notify` schedules and has none.
  """
  @callback phone(Operator.Core.Phone.action(), map()) :: :ok | {:error, term()}

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
  def request_permission(capability) do
    _ = :mob_nif.request_permission(capability)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def authenticate(reason) do
    _ = :mob_biometric_nif.biometric_authenticate(reason)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def confirm_approval(subject), do: Biometric.confirm(subject)

  @impl true
  def phone(action, args) do
    _ = start_phone(action, args)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  defp start_phone(:location, _args), do: MobLocation.get_once(nil)

  defp start_phone(:notify, a),
    do:
      MobNotify.schedule(nil, id: a.id, title: a.title, body: a.body, delay_seconds: a.in_seconds)

  defp start_phone(:camera_photo, _args), do: MobCamera.capture_photo(nil, quality: :medium)
  defp start_phone(:pick_photos, a), do: MobPhotos.pick(nil, max: a.max, types: [:image, :video])

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

  # Mob.Test.scroll_info/2's shape, plus what index lists report beyond it:
  # px scrolled into the first visible item, and whether it's at the end.
  defp decode(json) do
    m = Jason.decode!(json)

    info = %{
      offset: {f(m["offset_x"]), f(m["offset_y"])},
      content: {f(m["content_w"]), f(m["content_h"])},
      viewport: {f(m["viewport_w"]), f(m["viewport_h"])},
      max_offset: {f(m["max_x"]), f(m["max_y"])},
      kind: if(m["kind"] == "index", do: :index, else: :pixel)
    }

    case m do
      %{"first_offset" => px, "at_end" => at_end} when is_boolean(at_end) ->
        Map.merge(info, %{first_offset: f(px), at_end: at_end})

      _ ->
        info
    end
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

    * Following, and the position didn't go back since the last check: keep
      following (the list only moves down by our own scrolling).
    * Following, and the position went back: the user scrolled up; stop.
      Still at the end counts as following (rows replaced under the reader
      can nudge the position back without anyone scrolling).
    * Not following: resume once the user is back at the bottom.

  Android's lazy list reports item indexes (`:index`) plus the px scrolled
  into the first visible item (`:first_offset`) and `:at_end`; iOS a pixel
  scroll view (`:pixel`). The position on an index list is
  `{index, first_offset}`, so scrolling inside one reply taller than the
  screen counts, and that reply growing while it streams doesn't move it.
  """

  @typep position :: float() | {float(), float()}

  @doc """
  `{following, position_to_remember}` from the list's scroll info, whether
  we were following, and the position seen at the last check (nil at
  first). Without scroll info (host, list not laid out yet) nothing changes.
  """
  @spec decide(map() | {:error, term()} | nil, boolean(), position() | nil) ::
          {boolean(), position() | nil}
  def decide(%{offset: _} = info, true, last) do
    at = position(info)
    {last == nil or not went_back?(info, at, last) or Map.get(info, :at_end, false), at}
  end

  def decide(%{offset: _} = info, false, _last), do: {at_bottom?(info), position(info)}
  def decide(_unavailable, following, last), do: {following, last}

  defp position(%{kind: :index, offset: {_, i}, first_offset: px}), do: {i, px}
  defp position(%{offset: {_, y}}), do: y

  # How far back the position may move without counting as a user scroll:
  # px inside an item (and pixel views), or half an item without px info.
  @px_slack 24.0
  defp went_back?(_info, {i, px}, {last_i, last_px}),
    do: i < last_i or (i == last_i and px < last_px - @px_slack)

  defp went_back?(%{kind: :index}, y, last) when is_float(last), do: y < last - 0.5
  defp went_back?(_info, y, last) when is_float(y) and is_float(last), do: y < last - 4.0
  # The list changed kind of report between checks: start over from here.
  defp went_back?(_info, _at, _last), do: false

  @spec at_bottom?(map()) :: boolean()
  def at_bottom?(%{kind: :index, at_end: at_end}), do: at_end
  def at_bottom?(%{kind: :index, offset: {_, y}, max_offset: {_, max}}), do: max - y <= 1.0

  def at_bottom?(%{kind: :pixel, offset: {_, y}, max_offset: {_, max}, viewport: {_, vh}}),
    do: max - y <= max(vh * 0.15, 32.0)

  @doc """
  Where `scroll_to/3` should go to show the end: the last item (an index
  past the max goes to the bottom of the last item) or the max offset.
  """
  @spec bottom(map()) :: {float(), float()}
  def bottom(%{kind: :index, content: {_, items}}), do: {0.0, max(items - 1.0, 0.0)}
  def bottom(%{kind: :pixel, max_offset: {_, max}}), do: {0.0, max}
end
