defmodule CodeMySpec.Requirements.PredicatesTest do
  @moduledoc """
  Whether a check asked as a query answers what the interpreter answers.

  `RequirementCalculator` walks preloaded lists in Elixir; these emit SQL. They
  have to agree exactly, because the graph means one thing to a reader and
  another to the stop hook otherwise — and the disagreement would be silent, a
  requirement simply reported satisfied by one path and not the other.

  So these compare the two directly per component rather than asserting either
  answer alone, the same property the delegate batching is held to.
  """
  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Requirements.{Node, Predicates, RequirementGraph}

  setup do
    %{scope: full_scope_fixture()}
  end

  defp file!(scope, component, role, valid) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      harness_id: scope.active_harness_id,
      component_id: component.id,
      path: "lib/demo/#{role}_#{System.unique_integer([:positive])}.ex",
      role: role,
      valid: valid
    })
  end

  # What the query says, as a set of component ids.
  defp by_query(scope, check, config) do
    Predicates.nodes()
    |> where([node: n], not is_nil(n.component_id))
    |> Predicates.satisfied(check, config)
    |> select([node: n], n.component_id)
    |> Repo.all()
    |> MapSet.new()
    |> then(&{scope, &1})
    |> elem(1)
  end

  # What the interpreter says, from the same rows the graph would load.
  defp by_interpreter(scope, role, check) do
    FileRecord
    |> where([f], f.harness_id == ^scope.active_harness_id and f.role == ^role)
    |> where([f], not is_nil(f.component_id))
    |> Repo.all()
    |> Enum.filter(fn f -> check == :file_exists or f.valid == true end)
    |> Enum.map(& &1.component_id)
    |> MapSet.new()
  end

  describe "file_exists agrees with the interpreter" do
    test "a component with a spec is in both, one without is in neither", %{scope: scope} do
      with_spec = component_fixture(scope, %{type: "context"})
      _without = component_fixture(scope, %{type: "context"})
      file!(scope, with_spec, :spec, true)

      RequirementGraph.compute_graph(scope)

      assert by_query(scope, :file_exists, %{role: :spec}) ==
               by_interpreter(scope, :spec, :file_exists)
    end

    # Existence does not care about validity, and conflating them would make
    # `spec_file` and `spec_valid` the same requirement.
    test "an invalid file still exists", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      file!(scope, component, :spec, false)

      RequirementGraph.compute_graph(scope)

      assert MapSet.member?(by_query(scope, :file_exists, %{role: :spec}), component.id)
    end
  end

  describe "file_valid agrees with the interpreter" do
    test "only the valid one is satisfied", %{scope: scope} do
      good = component_fixture(scope, %{type: "context"})
      bad = component_fixture(scope, %{type: "context"})
      file!(scope, good, :spec, true)
      file!(scope, bad, :spec, false)

      RequirementGraph.compute_graph(scope)

      satisfied = by_query(scope, :file_valid, %{role: :spec})

      assert satisfied == by_interpreter(scope, :spec, :file_valid)
      assert MapSet.member?(satisfied, good.id)
      refute MapSet.member?(satisfied, bad.id)
    end

    # `valid: nil` is "synced but not yet validated", which `has_valid_role?/2`
    # reports as unsatisfied with its own reason. A predicate has to agree with
    # the verdict even though it cannot carry the reason.
    test "a file not yet validated is not valid", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      file!(scope, component, :spec, nil)

      RequirementGraph.compute_graph(scope)

      refute MapSet.member?(by_query(scope, :file_valid, %{role: :spec}), component.id)
    end
  end

  # The point of a query over an interpreter: it can be asked about the set.
  # `RequirementCalculator` answers one node at a time and cannot be.
  test "the predicate counts without computing a graph", %{scope: scope} do
    a = component_fixture(scope, %{type: "context"})
    b = component_fixture(scope, %{type: "context"})
    file!(scope, a, :implementation, true)
    file!(scope, b, :implementation, true)

    RequirementGraph.compute_graph(scope)

    # `implementation_file`, not `spec_file`: this project's configuration
    # strips the spec requirements, so no `spec_file` node exists to count and
    # the assertion below would have passed on 0 == 0.
    assert Repo.aggregate(from(n in Node, where: n.name == "implementation_file"), :count) == 2

    count =
      Predicates.nodes()
      |> where([node: n], n.name == "implementation_file")
      |> Predicates.satisfied(:file_exists, %{role: :implementation})
      |> Repo.aggregate(:count)

    assert count == 2
  end

  test "nodes/0 names its binding so fragments can correlate", %{scope: scope} do
    component_fixture(scope, %{type: "context"})
    RequirementGraph.compute_graph(scope)

    assert Repo.aggregate(Predicates.nodes(), :count) == Repo.aggregate(Node, :count)
  end
end
