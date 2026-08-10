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

  # A real second working copy of the same project. `harness_id` is a foreign
  # key, so a generated UUID is not a second checkout — it is a constraint
  # error, and the difference matters because the thing under test is what
  # happens when two checkouts both file rows.
  defp second_harness(scope) do
    {:ok, harness} = CodeMySpec.Harnesses.issue(scope, nil, label: "the other checkout")
    harness.id
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

  # The input that makes the two implementations differ, which the agreement
  # tests above cannot produce because they build one harness.
  #
  # `by_interpreter/3` filters on `harness_id`; the query did not. With a single
  # working copy both read the same rows and agreed perfectly, so the suite
  # asserted equality under exactly the condition where the difference cannot
  # appear. The moduledoc's argument — "scoped to one, first-found and any-valid
  # are the same question" — was written about a scoping the code never applied.
  describe "another checkout's files are not this one's evidence" do
    test "a spec written in a second harness does not satisfy the first", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      other_harness = second_harness(scope)

      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        harness_id: other_harness,
        component_id: component.id,
        path: "lib/demo/written_elsewhere.ex",
        role: :spec,
        valid: true
      })

      RequirementGraph.compute_graph(scope)

      satisfied =
        Predicates.nodes()
        |> where([node: n], not is_nil(n.component_id))
        |> Predicates.satisfied(:file_exists, %{role: :spec}, scope.active_harness_id)
        |> select([node: n], n.component_id)
        |> Repo.all()
        |> MapSet.new()

      refute MapSet.member?(satisfied, component.id),
             "a file that exists only in another working copy is work this checkout " <>
               "still has to do — reporting it done is work skipped and never noticed"
    end

    test "a nil harness blends every checkout, as the preloader does", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})

      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        harness_id: second_harness(scope),
        component_id: component.id,
        path: "lib/demo/written_elsewhere.ex",
        role: :spec,
        valid: true
      })

      RequirementGraph.compute_graph(scope)

      satisfied =
        Predicates.nodes()
        |> where([node: n], not is_nil(n.component_id))
        |> Predicates.satisfied(:file_exists, %{role: :spec}, nil)
        |> select([node: n], n.component_id)
        |> Repo.all()
        |> MapSet.new()

      assert MapSet.member?(satisfied, component.id),
             "the loose default is the UI's read — one rule with the preloader, not " <>
               "a second one invented here"
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
