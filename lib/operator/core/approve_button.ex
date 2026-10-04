defmodule Operator.Core.ApproveButton do
  @moduledoc """
  The approve chip for a self-change (a `Mob.UI.native_view` component):
  tapping it shows the system screen-lock prompt, which takes a fingerprint
  or face as well as the phone's PIN, pattern, password or passcode. Android
  runs it in `OperatorApproval.kt` (`BiometricPrompt`), iOS in
  `ios/OperatorApproval.swift` (`LAContext`, `.deviceOwnerAuthentication`),
  both registered as `"Operator_Core_ApproveButton"` (`MainActivity`,
  `ios/OperatorViews.swift`); off the phone screens show a plain button.

  A pass is only the human's say-so: the screen then records it
  (`Operator.Core.Dyn.Approval.Biometric.confirm/1`) and asks for the token
  (`Operator.Core.Dyn.request_approval/2`).

  Props:

    * `:notify`: the pid that gets the events (the screen)
    * `:subject`: what is being approved (`t:Operator.Core.Dyn.Approval.subject/0`),
      handed back with every event
    * `:label` (the chip's text), `:title`, `:subtitle` (the prompt's)
    * `:text_color`, `:background`: ARGB integers
    * `:text_size` (sp), `:font`: the face by the name the platform loads it
      by (an Android font resource name, an iOS PostScript name)

  `:notify` and `:subject` stay on the BEAM side; the native view gets
  `:request`, the subject as a string. A prompt answers with the `request` it
  was opened for, the view cancels a prompt whose `request` changes (a newer
  proposal took the chip over), and an answer for any other request than the
  current one is dropped: a pass only ever approves what the prompt showed.

  Each native event goes to `:notify` as `{:approval, event, payload}`, the
  payload carrying `"subject"`: `"approved"`, `"failed"` (with `"reason"`:
  `"canceled"`, `"lockout"`, `"timeout"` (Android), `"mismatch"` (iOS: the
  face, finger or passcode didn't match, too many times) or
  `"error_<code>"`: the platform's error code), or `"unavailable"` (the
  phone has no screen lock).
  """
  use Mob.Component

  require Logger

  @impl true
  def mount(props, socket) do
    socket
    |> Mob.Socket.assign(notify: props[:notify], subject: props[:subject])
    |> Mob.Socket.assign(:props, Map.drop(props, [:module, :id, :notify, :subject]))
    |> then(&{:ok, &1})
  end

  @impl true
  def render(%{props: props, subject: subject}), do: Map.put(props, :request, request(subject))

  @impl true
  def handle_event(event, payload, socket) do
    %{notify: pid, subject: subject} = socket.assigns
    {request, payload} = Map.pop(payload, "request")

    cond do
      request != request(subject) ->
        Logger.info("[approve_button] dropped #{event} for #{inspect(request)}")

      pid ->
        send(pid, {:approval, event, Map.put(payload, "subject", subject)})

      true ->
        :ok
    end

    {:noreply, socket}
  end

  defp request(subject), do: inspect(subject)

  @doc ~S|Why an approval didn't happen, in plain words, for a "failed" or "unavailable" event.|
  @spec why(String.t(), map()) :: String.t()
  def why("unavailable", _payload),
    do: "Approve needs a screen lock (a PIN, pattern, password or passcode) on this phone"

  def why("failed", %{"reason" => "canceled"}), do: "the prompt was cancelled"

  def why("failed", %{"reason" => "lockout"}),
    do: "too many wrong tries; wait a moment and try again"

  def why("failed", %{"reason" => "timeout"}), do: "the prompt timed out"
  def why("failed", %{"reason" => "mismatch"}), do: "it didn't recognise you; try again"
  def why("failed", payload), do: "the check failed (#{payload["reason"] || "unknown"})"
end
