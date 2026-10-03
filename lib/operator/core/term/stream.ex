defmodule Operator.Core.Term.Stream do
  @moduledoc """
  Markdown for text that is still streaming: finished lines are parsed once
  and kept; only the unfinished last line is re-parsed on each `lines/1`.
  """

  alias Operator.Core.Term.Markup

  defstruct parsed: nil, tail: ""

  @type t :: %__MODULE__{parsed: {[Markup.line()], Markup.state()}, tail: String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{parsed: Markup.initial()}

  @spec feed(t(), String.t()) :: t()
  def feed(%__MODULE__{} = s, delta) do
    case String.split(s.tail <> delta, "\n") do
      [tail] ->
        %{s | tail: tail}

      parts ->
        {complete, [tail]} = Enum.split(parts, -1)
        %{s | parsed: Enum.reduce(complete, s.parsed, &Markup.push/2), tail: tail}
    end
  end

  @spec lines(t()) :: [Markup.line()]
  def lines(%__MODULE__{tail: "", parsed: {rev, _}}), do: Enum.reverse(rev)

  def lines(%__MODULE__{tail: tail, parsed: parsed}) do
    {rev, _state} = Markup.push(tail, parsed)
    Enum.reverse(rev)
  end
end
