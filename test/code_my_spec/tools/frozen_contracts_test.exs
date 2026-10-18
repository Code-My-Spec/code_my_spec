defmodule CodeMySpec.Tools.FrozenContractsTest do
  @moduledoc """
  A tool moved into its domain keeps the name, description and argument schema
  it had as an MCP component. Each fixture under `test/fixtures/tool_contracts/`
  was written from the components before they were deleted; names are what role
  grants and agents' cached tool lists point at, so drift here breaks agents
  without failing anything else.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  @fixtures Path.wildcard("test/fixtures/tool_contracts/*.json")

  for fixture <- @fixtures do
    @fixture fixture
    test "#{Path.basename(fixture, ".json")} tools keep their original contracts" do
      original = @fixture |> File.read!() |> Jason.decode!()
      names = Enum.map(original, & &1["name"])

      actual =
        ToolLibrary.registrations()
        |> Enum.filter(&(&1.name in names))
        |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))
        |> Enum.sort_by(& &1.name)
        |> Jason.encode!()
        |> Jason.decode!()

      assert actual == Enum.sort_by(original, & &1["name"])
    end
  end
end
