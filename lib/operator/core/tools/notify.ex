defmodule Operator.Core.Tools.Notify do
  @moduledoc "Core tool: a local notification on the phone, now or after a delay."
  @behaviour Operator.Core.Tool

  alias Operator.Core.Tools.PhoneTool

  @max_delay 7 * 24 * 3600

  @impl true
  def name, do: "notify"

  @impl true
  def description,
    do:
      "Show a notification on the phone, now or after `in_seconds` (a reminder). " <>
        "Use it for things the user should see even when the app is closed."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "body" => %{"type" => "string"},
        "in_seconds" => %{"type" => "integer", "minimum" => 0, "maximum" => @max_delay}
      },
      "required" => ["title", "body"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 15_000

  @impl true
  def run(%{"title" => title, "body" => body} = args, ctx)
      when is_binary(title) and is_binary(body) and title != "" do
    delay = args["in_seconds"] || 0

    with true <- is_integer(delay) and delay in 0..@max_delay,
         {:ok, id} <-
           PhoneTool.call(:notify, %{title: title, body: body, in_seconds: delay}, ctx, 10_000) do
      {:ok, "Notification #{id} scheduled #{if delay == 0, do: "now", else: "in #{delay} s"}."}
    else
      false -> {:error, "in_seconds must be 0..#{@max_delay}"}
      {:error, _} = error -> error
    end
  end

  def run(_args, _ctx), do: {:error, "notify needs a non-empty `title` and a `body`"}

  @impl true
  def selftest,
    do:
      PhoneTool.selftest(
        &run(%{"title" => "t", "body" => "b", "in_seconds" => 5}, &1),
        {:ok, "n1"},
        &(&1 == {:ok, "Notification n1 scheduled in 5 s."})
      )
end
