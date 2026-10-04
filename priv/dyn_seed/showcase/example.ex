defmodule Operator.Dyn.Showcase.Example do
  @moduledoc """
  One showcased example: a `title`, a short `description`, the `code` to show
  (a plain string) and a `render` function returning the live preview node.
  """
  @enforce_keys [:title, :render]
  defstruct [:title, :description, :code, :render]
end
