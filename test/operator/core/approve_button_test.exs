defmodule Operator.Core.ApproveButtonTest do
  use ExUnit.Case, async: true

  alias Operator.Core.ApproveButton

  defp mount(props) do
    {:ok, socket} = ApproveButton.mount(props, Mob.Socket.new(ApproveButton))
    socket
  end

  test "the native view gets only its own props; events reach :notify with the subject" do
    socket =
      mount(%{
        module: ApproveButton,
        id: :approve_revert,
        notify: self(),
        subject: {:revert_to, 2},
        label: "Approve revert to G2",
        title: "Revert to generation 2"
      })

    assert %{label: "Approve revert to G2", title: "Revert to generation 2", request: request} =
             props = ApproveButton.render(socket.assigns)

    assert map_size(props) == 3

    ApproveButton.handle_event("failed", %{"reason" => "canceled", "request" => request}, socket)
    assert_received {:approval, "failed", %{"reason" => "canceled", "subject" => {:revert_to, 2}}}
  end

  test "a prompt opened for one subject never answers for the next one" do
    socket = mount(%{notify: self(), subject: {:activate, 2}})
    old = ApproveButton.render(socket.assigns).request
    {:ok, socket} = ApproveButton.update(%{notify: self(), subject: {:activate, 3}}, socket)
    new = ApproveButton.render(socket.assigns).request
    assert old != new

    # the pass the human gave generation 2's prompt doesn't approve generation 3
    ApproveButton.handle_event("approved", %{"request" => old}, socket)
    refute_received {:approval, _, _}

    # nor does an answer that names no request
    ApproveButton.handle_event("approved", %{}, socket)
    refute_received {:approval, _, _}

    ApproveButton.handle_event("approved", %{"request" => new}, socket)
    assert_received {:approval, "approved", %{"subject" => {:activate, 3}} = payload}
    refute Map.has_key?(payload, "request")
  end
end
