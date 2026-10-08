defmodule CodeMySpec.Requirements.EdgesCycleTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.{Edges, Topology}

  @bdd {"story", 601, "bdd_specs_exist"}
  @qa {"story", 601, "ready_for_qa"}
  @users {"component", "users", "implementation_file"}
  @dependency {"component", "dependency", "implementation_file"}
  @downstream {"component", "downstream", "implementation_file"}

  test "a cycle cannot remove the only exit into ready_for_qa" do
    result = reduce(cycle(), [@users])

    assert edge(@users, @qa) in result.edges
    assert edge(@bdd, @dependency) in result.edges
    refute edge(@bdd, @qa) in result.edges
  end

  test "mutually reachable exits do not eliminate one another" do
    result = reduce(cycle(), [@users, @dependency])

    assert edge(@users, @qa) in result.edges
    assert edge(@dependency, @qa) in result.edges
  end

  test "a strictly downstream exit still replaces upstream exits" do
    result = reduce(cycle() ++ [edge(@users, @downstream)], [@users, @dependency, @downstream])

    assert edge(@downstream, @qa) in result.edges
    refute edge(@users, @qa) in result.edges
    refute edge(@dependency, @qa) in result.edges
  end

  test "acyclic exits retain their existing reduction" do
    result = reduce([edge(@dependency, @users)], [@dependency, @users])

    assert edge(@users, @qa) in result.edges
    refute edge(@dependency, @qa) in result.edges
  end

  defp reduce(component_edges, exits) do
    Edges.story_side(
      %{
        template: [edge(@bdd, @qa)],
        kickoff: [edge(@bdd, @dependency)],
        exit: Enum.map(exits, &edge(&1, @qa)),
        project: []
      },
      %{reach: Topology.reach(component_edges)},
      fn _ -> true end
    )
  end

  defp cycle, do: [edge(@users, @dependency), edge(@dependency, @users)]
  defp edge(from, to), do: %{from: from, to: to}
end
