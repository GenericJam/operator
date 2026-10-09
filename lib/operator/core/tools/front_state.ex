defmodule Operator.Core.Tools.FrontState do
  @moduledoc """
  Core tool: the open front screen's state, its assigns
  (`Operator.Core.Front.assigns/1`), so the agent can check what a tap or a
  delivered message did without reading it off a screenshot. Read from the
  screen's process without running its code; printed with limits, since
  assigns may hold a photo's bytes or a long list. Acts on `ctx[:front]` if
  given.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Front

  @max_bytes 8_000

  @impl true
  def name, do: "front_state"

  @impl true
  def description,
    do:
      "Show the open front screen's state: its module and its assigns (socket.assigns), " <>
        "as Elixir terms (long lists and strings cut). Use it to check what a front_tap or " <>
        "front_send did, or why a screen shows what it shows. `keys`: only these assigns."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "keys" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Assign names to show (e.g. [\"photo\", \"error\"]); all if omitted."
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  # The front has one screen: no other front call runs alongside.
  @impl true
  def concurrency, do: :exclusive

  @impl true
  def run(args, ctx) do
    case Front.assigns(Map.get(ctx, :front, Front)) do
      {:ok, screen, assigns} ->
        {:ok, render(screen, pick(assigns, args["keys"]))}

      {:error, :not_running} ->
        {:error,
         "No front screen is running (or it is busy in its own code): open one with " <>
           "front_open, or see front_screens."}
    end
  end

  defp pick(assigns, keys) when is_list(keys) and keys != [] do
    by_name = Map.new(assigns, fn {k, v} -> {to_string(k), {k, v}} end)
    {found, missing} = Enum.split_with(keys, &Map.has_key?(by_name, &1))
    {Map.new(found, &Map.fetch!(by_name, &1)), missing, Map.keys(by_name)}
  end

  defp pick(assigns, _keys), do: {assigns, [], []}

  defp render(screen, {assigns, missing, all}) do
    body =
      inspect(assigns, pretty: true, limit: 50, printable_limit: 500, width: 80)
      |> cap()

    note =
      if missing == [],
        do: "",
        else:
          "\n(no assign #{Enum.join(missing, ", ")}; it has: " <>
            "#{all |> Enum.sort() |> Enum.join(", ")})"

    "#{screen} assigns:\n#{body}#{note}"
  end

  defp cap(text) when byte_size(text) <= @max_bytes, do: text

  defp cap(text) do
    head =
      case :unicode.characters_to_binary(binary_part(text, 0, @max_bytes)) do
        valid when is_binary(valid) -> valid
        {_, valid, _} -> valid
      end

    head <> "\n… (cut at #{@max_bytes} bytes of #{byte_size(text)}; pass `keys` for fewer)"
  end

  @impl true
  def selftest do
    with "S assigns:\n%{a: 1}" <- render("S", pick(%{a: 1, b: 2}, ["a"])),
         "S assigns:\n%{}\n(no assign z; it has: a)" <- render("S", pick(%{a: 1}, ["z"])),
         true <- byte_size(cap(String.duplicate("x", 9_000))) < 8_100 do
      :ok
    else
      other -> {:error, other}
    end
  end
end
