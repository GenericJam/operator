defmodule Operator.Core.Tools.CameraPhoto do
  @moduledoc "Core tool: the user takes a photo with the camera; returns the saved file."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.PhoneTool

  @impl true
  def name, do: "camera_photo"

  @impl true
  def description,
    do:
      "Open the camera so the user can take a photo; returns where it was saved and its size. " <>
        "The user can cancel. (You get the file's path, not the image itself.)"

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 180_000

  @impl true
  def run(_args, ctx) do
    case PhoneTool.call(:camera_photo, %{}, ctx, 175_000) do
      {:ok, %{path: path} = photo} ->
        {:ok, "Photo saved: #{path} (#{photo[:width]}×#{photo[:height]})"}

      {:ok, :cancelled} ->
        {:ok, "The user cancelled the camera."}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{}, &1),
        {:ok, %{path: "/tmp/p.jpg", width: 4, height: 3}},
        &(&1 == {:ok, "Photo saved: /tmp/p.jpg (4×3)"})
      )
end
