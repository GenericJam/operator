defmodule Operator.Core.MarkdownView do
  @moduledoc """
  A native Markdown view for one stretch of an assistant reply (a
  `Mob.UI.native_view` component, built by `Operator.Core.Term` for the
  `:native` renderer). Android draws it with Markwon in a selectable
  `TextView` (`OperatorMarkdown.kt`), iOS with Foundation's Markdown parser
  in a read-only selectable `UITextView` (`ios/OperatorMarkdown.swift`;
  tables drawn as box-drawing text in the monospace face, cells wrapped to
  the view's width); both register it as `"Operator_Core_MarkdownView"`
  (`MainActivity`, `ios/OperatorViews.swift`).

  Props (all forwarded to the native view as they are):

    * `:text`: the Markdown (CommonMark + GFM tables / strikethrough,
      autolinked URLs, the inline HTML omp renders)
    * `:text_size` (sp), `:line_height` (a multiplier)
    * `:text_color`, `:heading_color`, `:link_color`, `:code_color`,
      `:code_background`, `:quote_color`, `:rule_color`, `:selection_color`:
      ARGB integers
    * `:font_regular`, `:font_bold`, `:font_italic`, `:font_bold_italic`:
      the faces by the names the platform loads them by: Android font
      resource names (`res/font`, copied from `priv/fonts`), iOS PostScript
      names (bundled from `priv/fonts`)

  Events: a tapped link sends `"open_link"` with `%{"url" => url}`; web and
  mail links open in the system (`Mob.Device.open_url/1`), anything else
  (`intent:`, `file:`, `javascript:`, …) is ignored, since the text is the
  model's.
  """
  use Mob.Component

  require Logger

  @openable ~w(http https mailto)

  @impl true
  def mount(props, socket),
    do: {:ok, Mob.Socket.assign(socket, :props, Map.drop(props, [:module, :id]))}

  @impl true
  def render(%{props: props}), do: props

  @impl true
  def handle_event("open_link", %{"url" => url}, socket) when is_binary(url) do
    if openable?(url),
      do: Mob.Device.open_url(url),
      else: Logger.info("[markdown_view] not opening #{inspect(URI.parse(url).scheme)} link")

    {:noreply, socket}
  end

  def handle_event(_event, _payload, socket), do: {:noreply, socket}

  @doc "Whether a tapped link may be opened: web and mail links only."
  @spec openable?(String.t()) :: boolean()
  def openable?(url), do: String.downcase(URI.parse(url).scheme || "") in @openable
end
