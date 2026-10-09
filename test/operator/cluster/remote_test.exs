defmodule Operator.Cluster.RemoteTest.Location do
  @moduledoc "Stands in for the `location` tool: a fixed fix."
  @behaviour Operator.Core.Tool

  @impl true
  def name, do: "location"
  @impl true
  def description, do: "A fixed location."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(_args, %{peer: peer}), do: {:ok, "51.05, -114.07 for #{peer}"}
end

defmodule Operator.Cluster.RemoteTest do
  # The tool registry and the Dyn Keeper are app-wide names.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Cluster.Remote
  alias Operator.Cluster.RemoteTest.Location
  alias Operator.Core.ToolRegistry

  @moduletag :tmp_dir
  @moduletag :capture_log

  @peer :"operator_aaaa111111@10.0.0.2"

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  test "the Core tools added since peers could run tools are refused, even when registered" do
    start_supervised!({ToolRegistry, tools: ToolRegistry.core_tools()})

    for name <- ~w(eval logs instructions skill todo task front_send front_tap) do
      assert {:ok, _} = ToolRegistry.lookup(name)
      assert {:error, text} = Remote.answer({:tool, name, %{}}, @peer)
      assert text == "#{name} only runs for this phone's own agent"
    end
  end

  test "an allowed Core tool runs for a peer" do
    start_supervised!({ToolRegistry, tools: [Location]})

    assert Remote.answer({:tool, "location", %{}}, @peer) ==
             {:ok, "51.05, -114.07 for #{@peer}"}
  end

  test "a tool registered at runtime is refused unless it is on the list" do
    start_supervised!({ToolRegistry, tools: []})
    :ok = ToolRegistry.register(Operator.Test.Tools.Echo)

    assert {:error, "echo only runs for this phone's own agent"} =
             Remote.answer({:tool, "echo", %{"text" => "hi"}}, @peer)
  end

  test "the current Dyn generation's tools still run for a peer", %{tmp_dir: dir} do
    start_supervised!({ToolRegistry, tools: []})
    start_keeper(dir)
    activate!(%{"weather.ex" => tool("Weather", "weather")})

    assert Remote.answer({:tool, "weather", %{}}, @peer) == {:ok, "ran weather"}
  end
end
