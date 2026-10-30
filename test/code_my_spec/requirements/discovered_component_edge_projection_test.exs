defmodule CodeMySpec.Requirements.DiscoveredComponentEdgeProjectionTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo

  alias CodeMySpec.Requirements.{GraphInputs, IncrementalGraph, Preloader, RequirementGraph}

  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup do
    %{scope: full_scope_fixture()}
  end

  @child_path "lib/example/accounts/user.ex"

  # A discovered component's record says write its file. Every checkout shares
  # its edges; one without the file has the requirement unsatisfied, not the
  # component missing from the graph.
  test "a discovered child is in every checkout's graph, file or not", %{scope: first} do
    {:ok, context} =
      Components.create_component(first, %{
        name: "Accounts",
        type: "context",
        module_name: "Example.Accounts"
      })

    {:ok, child} =
      Components.create_component(first, %{
        name: "User",
        type: "module",
        module_name: "Example.Accounts.User",
        parent_component_id: context.id,
        provenance: :discovered
      })

    {:ok, story} =
      Stories.create_story(first, %{
        ready_for_dev: true,
        title: "Manage an account user",
        description: "As an operator, I manage an account user",
        acceptance_criteria: ["The user is saved"],
        component_id: child.id
      })

    {:ok, copy} = WorkingCopies.issue(first, nil, label: "Other", device: device_fixture(first))
    second = %{first | active_working_copy_id: copy.id}

    file = insert_file(first, child.id)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    assert child_edge?(first, child.id)
    assert child_edge?(second, child.id)
    refute child_satisfied?(second, child.id), "the second checkout has no file for it"

    {:ok, _} =
      Stories.update_story(first, story, %{description: "The account user can be managed"})

    settle_both(first, second)
    assert_clean_projection(first)
    assert_clean_projection(second)

    # Removing and restoring the file moves verdicts, never edges.
    Repo.delete!(file)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    assert child_edge?(first, child.id)
    assert child_edge?(second, child.id)
    refute child_satisfied?(first, child.id), "the first checkout's file is gone"
    assert_clean_projection(first)
    assert_clean_projection(second)

    insert_file(first, child.id)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    assert child_edge?(first, child.id)
    assert child_edge?(second, child.id)
    assert_clean_projection(first)
    assert_clean_projection(second)
  end

  defp insert_file(scope, component_id) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      component_id: component_id,
      path: @child_path,
      role: :implementation,
      valid: true
    })
  end

  defp announce_file_membership(scope, component_id) do
    GraphInputs.event(
      scope,
      "DiscoveredComponentEdgeProjectionTest",
      "files_synced",
      %{},
      [{"component", component_id}],
      :this_checkout
    )
  end

  defp settle_both(first, second) do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(first)

    :ok =
      IncrementalGraph.settle(first.active_project_id, [
        first.active_working_copy_id,
        second.active_working_copy_id
      ])
  end

  defp child_edge?(scope, component_id) do
    ctx = Preloader.topology_context(scope)
    {_nodes, edges} = RequirementGraph.served_graph(scope, ctx)

    Enum.any?(edges, fn edge ->
      match?({"story", _, _}, edge.from) and
        match?({"component", ^component_id, _}, edge.to)
    end)
  end

  # Every requirement of the component holds at this checkout.
  defp child_satisfied?(scope, component_id) do
    {nodes, _edges} = RequirementGraph.served_graph(scope, Preloader.topology_context(scope))

    nodes
    |> Enum.filter(&(&1.entity_type == "component" and &1.entity_id == component_id))
    |> Enum.all?(& &1.satisfied)
  end

  defp assert_clean_projection(scope) do
    report = CodeMySpec.Requirements.served_vs_recomputed(scope)

    assert report.missing == 0
    assert report.extra == 0
    assert report.disagree == 0
    assert report.edges_missing == 0
    assert report.edges_extra == 0
    assert report.actionable_disagree == 0
  end
end
