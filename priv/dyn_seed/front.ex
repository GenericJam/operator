defmodule Operator.Dyn.Front do
  @moduledoc """
  The front's settings, read by Operator's shell: `start/0` is the screen
  the front opens on (until another is opened), `toggle/0` the symbol of the
  front/terminal toggle in the upper left corner (`:dial`, Operator's logo,
  or `{:text, "☎"}`, a short glyph).
  """

  def start, do: Operator.Dyn.Showcase.GalleryScreen
  def toggle, do: :dial
end
