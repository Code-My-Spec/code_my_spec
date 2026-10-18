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
        |> normalize()

      assert actual == original |> Enum.sort_by(& &1["name"]) |> normalize()
    end
  end

  # `required` is a set in JSON Schema; its order follows map iteration.
  defp normalize(%{"required" => required} = map) when is_list(required),
    do:
      map
      |> Map.put("required", Enum.sort(required))
      |> Map.new(fn {k, v} -> {k, normalize(v)} end)

  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end
