defmodule Operator.Core.Terminal do
  @moduledoc """
  What a front screen may ask of the terminal: to be shown, optionally with
  a draft in the composer (the component library's "use this" hands a
  component to the agent this way). The one Core API besides the tool
  behaviour, the files and TFLite that Dyn code may call
  (`Operator.Core.Dyn.Check`).

  It's safe to hand Dyn code because it can't do anything the user
  wouldn't see and confirm: the draft is never sent (the user reads it and
  presses Send, or doesn't), and only the front screen on display may ask
  (`Operator.Core.Front` checks the caller is its host and the front is
  showing), so a Dyn tool or a screen in the background can't pull the
  user away from what they're doing.
  """

  alias Operator.Core.Front

  @max_bytes 2_000

  @doc """
  Shows the terminal with `text` added to the composer's draft (after
  anything typed there), unsent. Only from the front screen on display:
  `{:error, :not_in_front}` otherwise.
  """
  @spec draft(String.t()) :: :ok | {:error, :not_in_front | :too_long | :not_text}
  def draft(text) when is_binary(text) do
    cond do
      not String.valid?(text) -> {:error, :not_text}
      byte_size(text) > @max_bytes -> {:error, :too_long}
      true -> Front.to_terminal(self(), text)
    end
  end

  def draft(_text), do: {:error, :not_text}

  @doc "Shows the terminal (the composer as it was). Only from the front screen on display."
  @spec open() :: :ok | {:error, :not_in_front}
  def open, do: Front.to_terminal(self(), "")
end
