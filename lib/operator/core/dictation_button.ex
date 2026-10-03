defmodule Operator.Core.DictationButton do
  @moduledoc """
  The composer's mic: speech to text into the draft (a `Mob.UI.native_view`
  component). Android runs `SpeechRecognizer` in `OperatorDictation.kt`,
  registered as `"Operator_Core_DictationButton"` in `MainActivity`; there's
  no iOS view yet, so the chat screen only shows it on Android.

  Hold to talk (partial results stream into the draft); on release the
  final transcript lands in the draft to edit and send. Nothing is sent.

  Props:

    * `:notify`: the pid that gets the events (the chat screen); not passed
      to the native view
    * `:text_color`, `:active_color`, `:background`: ARGB integers
    * `:text_size` (sp), `:font`: an Android font resource name

  Each native event goes to `:notify` as `{:dictation, event, payload}`:
  `"state"` (`%{"state" => "listening" | "processing" | "idle"}`),
  `"partial"` and `"final"` (`%{"text" => ...}`), `"hint"` (released too
  quickly to say anything), `"error"` (`%{"reason" => ...}`), `"needs_permission"`.
  """
  use Mob.Component

  @impl true
  def mount(props, socket) do
    socket
    |> Mob.Socket.assign(:notify, props[:notify])
    |> Mob.Socket.assign(:props, Map.drop(props, [:module, :id, :notify]))
    |> then(&{:ok, &1})
  end

  @impl true
  def render(%{props: props}), do: props

  @impl true
  def handle_event(event, payload, socket) do
    if pid = socket.assigns.notify, do: send(pid, {:dictation, event, payload})
    {:noreply, socket}
  end
end
