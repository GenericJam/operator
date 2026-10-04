defmodule Operator.Core.Tools.ReadDoc do
  @moduledoc """
  Core tool: a module's documentation as the phone's BEAMs carry it
  (`Operator.Core.Docs.module_doc/2`): its moduledoc and public functions,
  or one function's doc in full.
  """
  @behaviour Operator.Core.Tool

  alias Operator.Core.Docs

  @impl true
  def name, do: "read_doc"

  @impl true
  def description do
    "Read a module's docs on this phone (the versions the app ships): moduledoc plus every " <>
      "public function's signature and summary, or with `function` that function's full doc. " <>
      "Check an API here before you use it, e.g. Mob.Socket, Mob.UI, MobLocation, " <>
      "MobMishka.Components.MishkaTabs."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "module" => %{"type" => "string", "description" => "e.g. Mob.Socket"},
        "function" => %{"type" => "string", "description" => "A function name, e.g. assign."}
      },
      "required" => ["module"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"module" => module} = args, _ctx) when is_binary(module) do
    case args["function"] do
      nil -> Docs.module_doc(module)
      function when is_binary(function) -> Docs.module_doc(module, String.trim(function))
      other -> {:error, "function must be a name, got #{inspect(other)}"}
    end
  end

  def run(_args, _ctx), do: {:error, "read_doc needs a `module`, e.g. Mob.Socket"}

  # A mob module: an over-the-air update strips the docs of Operator's own.
  @impl true
  def selftest do
    case run(%{"module" => "Mob.Socket", "function" => "assign"}, %{}) do
      {:ok, text} -> if text =~ "assign(", do: :ok, else: {:error, "selftest: #{text}"}
      {:error, reason} -> {:error, "selftest: #{reason}"}
    end
  end
end
