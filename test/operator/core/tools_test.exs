defmodule Operator.Core.ToolsTest do
  use ExUnit.Case, async: false

  alias Operator.Core.ToolRegistry
  alias Operator.Core.Tools.Notes

  @moduletag :tmp_dir

  test "notes: append and read back, and its selftest passes", %{tmp_dir: dir} do
    ctx = %{data_dir: dir}
    assert {:ok, "(no notes yet)"} = Notes.run(%{"action" => "read"}, ctx)

    assert {:ok, "Appended. Notes now have 1 lines."} =
             Notes.run(%{"action" => "append", "text" => "milk"}, ctx)

    assert {:ok, "milk\n"} = Notes.run(%{"action" => "read"}, ctx)
    assert {:error, _} = Notes.run(%{"action" => "append"}, ctx)
    assert {:error, _} = Notes.run(%{"action" => "delete"}, ctx)
    assert Notes.selftest() == :ok
  end

  test "the registry offers core tools and takes new ones at runtime" do
    start_supervised!(ToolRegistry)
    assert ToolRegistry.list() == [Notes]
    assert {:ok, Notes} = ToolRegistry.lookup("notes")

    assert :ok = ToolRegistry.register(Operator.Test.Tools.Echo)
    assert {:ok, Operator.Test.Tools.Echo} = ToolRegistry.lookup("echo")
    assert {:error, :not_a_tool} = ToolRegistry.register(String)

    :ok = ToolRegistry.unregister("echo")
    assert ToolRegistry.lookup("echo") == :error
  end
end
