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

  @impl true
  def request_permission(capability) do
    send(self(), {:requested_permission, capability})
    Process.get(:fake_native_result, :ok)
  end

  # Tests run the Keeper with Operator.Test.Dyn.Approval, which needs no confirmation.
  @impl true
  def confirm_approval(subject) do
    send(self(), {:confirmed, subject})
    :ok
  end

  @impl true
  def phone(action, args) do
    send(self(), {:phone_call, action, args})
    Process.get(:fake_native_result, :ok)
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

  @doc """
  The same list as Android reports it: also px scrolled into item `first`
  and whether it's at the end, which tells apart positions inside one item
  taller than the screen.
  """
  def index_info(first, visible, total, first_offset, at_end) do
    Map.merge(index_info(first, visible, total), %{
      first_offset: first_offset * 1.0,
      at_end: at_end
    })
  end
end
