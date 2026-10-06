defmodule Operator.Core.Tools.CameraPhoto do
  @moduledoc """
  Core tool: the user takes a photo with the camera app; the model sees it,
  kept in the workspace's `inbox/`. The same shot as the chat's
  `[attach] › take photo` (`Operator.Core.Attachments.take_photo/1`).
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Attachments
  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "camera_photo"

  @impl true
  def description,
    do:
      "Open the camera so the user can frame and take a photo; you see it, with its path (a " <>
        "copy in your workspace's inbox/). The user can cancel. To take one yourself without " <>
        "anyone touching the phone, use camera_snap."

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(_args, ctx),
    do: ctx |> Attachments.take_photo() |> Attachments.tool_result("Photo taken:")

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{}, &1),
        {:ok, :cancelled},
        &(&1 == {:ok, "The user cancelled."})
      )
end
