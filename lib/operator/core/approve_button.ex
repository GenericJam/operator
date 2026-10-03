defmodule Operator.Core.ApproveButton do
  @moduledoc """
  The approve chip for a self-change (a `Mob.UI.native_view` component):
  tapping it shows the system screen-lock prompt, which takes a fingerprint
  or face as well as the phone's PIN, pattern or password. Android runs it
  in `OperatorApproval.kt`, registered as `"Operator_Core_ApproveButton"`
  in `MainActivity`; there's no iOS view yet, so screens only show it on
  Android.

  A pass is only the human's say-so: the screen then records it
  (`Operator.Core.Dyn.Approval.Biometric.confirm/1`) and asks for the token
  (`Operator.Core.Dyn.request_approval/2`).

  Props:

    * `:notify`: the pid that gets the events (the screen)
    * `:subject`: what is being approved (`t:Operator.Core.Dyn.Approval.subject/0`),
      handed back with every event
    * `:label` (the chip's text), `:title`, `:subtitle` (the prompt's)
    * `:text_color`, `:background`: ARGB integers
    * `:text_size` (sp), `:font`: an Android font resource name

  `:notify` and `:subject` stay on the BEAM side.

  Each native event goes to `:notify` as `{:approval, event, payload}`, the
  payload carrying `"subject"`: `"approved"`, `"failed"` (with `"reason"`:
  `"canceled"`, `"lockout"`, `"timeout"` or `"error_<code>"`), or
  `"unavailable"` (the phone has no screen lock).
  """
  use Mob.Component

  @impl true
  def mount(props, socket) do
    socket
    |> Mob.Socket.assign(notify: props[:notify], subject: props[:subject])
    |> Mob.Socket.assign(:props, Map.drop(props, [:module, :id, :notify, :subject]))
    |> then(&{:ok, &1})
  end

  @impl true
  def render(%{props: props}), do: props

  @impl true
  def handle_event(event, payload, socket) do
    %{notify: pid, subject: subject} = socket.assigns
    if pid, do: send(pid, {:approval, event, Map.put(payload, "subject", subject)})
    {:noreply, socket}
  end

  @doc ~S|Why an approval didn't happen, in plain words, for a "failed" or "unavailable" event.|
  @spec why(String.t(), map()) :: String.t()
  def why("unavailable", _payload),
    do: "Approve needs a screen lock (PIN, pattern or password) on this phone"

  def why("failed", %{"reason" => "canceled"}), do: "the prompt was cancelled"

  def why("failed", %{"reason" => "lockout"}),
    do: "too many wrong tries; wait a moment and try again"

  def why("failed", %{"reason" => "timeout"}), do: "the prompt timed out"
  def why("failed", payload), do: "the check failed (#{payload["reason"] || "unknown"})"
end
