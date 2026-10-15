defmodule CodeMySpec.Knowledge.ToolsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.Users.Scope

  test "the migrated tools retain their original MCP contracts" do
    original =
      "test/fixtures/tool_contracts/knowledge.json"
      |> File.read!()
      |> Jason.decode!()

    actual =
      ToolLibrary.registrations()
      |> Enum.filter(&(&1.name in ~w(list_knowledge read_knowledge)))
      |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))
      |> Enum.sort_by(& &1.name)
      |> Jason.encode!()
      |> Jason.decode!()

    assert actual == original
  end

  test "code mode retains structured directory entries" do
    scope = %Scope{active_project_id: Ecto.UUID.generate()}

    assert {:ok, %{"type" => "dir", "entries" => entries}} =
             CodeMode.catalog(scope)["list_knowledge"].invoke.(%{})

    assert Enum.any?(entries, &(&1["name"] == "liveview" and &1["type"] == "dir"))
  end
end
