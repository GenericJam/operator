defmodule Operator.Test.FakeScanNative do
  @moduledoc """
  Stands in for `Operator.LoginScanScreen.Native` in screen tests: the
  screen runs in the test process (Mob.ScreenCase), so the calls arrive in
  the test's mailbox and the test feeds the answers back with `render_info/2`.
  """
  @behaviour Operator.LoginScanScreen.Native

  @impl true
  def request_camera do
    send(self(), :requested_camera)
    :ok
  end

  @impl true
  def scan do
    send(self(), :scanning)
    :ok
  end
end
