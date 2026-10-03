defmodule Operator.Test.FakeNative do
  @moduledoc """
  Stands in for `Operator.ChatScreen.Native` in screen tests. The screen runs
  in the test process (Mob.ScreenCase), so calls are reported to it as
  messages and the scroll position comes from the process dictionary.
  """
  @behaviour Operator.ChatScreen.Native

  @impl true
  def clipboard_put(text) do
    send(self(), {:clipboard, text})
    :ok
  end

  @impl true
  def scroll_info(_id), do: Process.get(:fake_scroll_info, {:error, :unavailable})

  @impl true
  def scroll_to(id, x, y) do
    send(self(), {:scrolled_to, id, x, y})
    :ok
  end

  @doc "A lazy list (Android, item indexes) showing items `first..first+visible-1` of `total`."
  def index_info(first, visible, total) do
    %{
      kind: :index,
      offset: {0.0, first * 1.0},
      content: {0.0, total * 1.0},
      viewport: {0.0, visible * 1.0},
      max_offset: {0.0, max(total - visible, 0) * 1.0}
    }
  end
end
