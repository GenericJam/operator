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

    assert ApproveButton.render(socket.assigns) == %{
             label: "Approve revert to G2",
             title: "Revert to generation 2"
           }

    ApproveButton.handle_event("failed", %{"reason" => "canceled"}, socket)
    assert_received {:approval, "failed", %{"reason" => "canceled", "subject" => {:revert_to, 2}}}
  end

  test "a re-render with another subject answers for the new one" do
    socket = mount(%{notify: self(), subject: {:revert_to, 2}})
    {:ok, socket} = ApproveButton.update(%{notify: self(), subject: {:revert_to, 1}}, socket)

    ApproveButton.handle_event("approved", %{}, socket)
    assert_received {:approval, "approved", %{"subject" => {:revert_to, 1}}}
  end
end
