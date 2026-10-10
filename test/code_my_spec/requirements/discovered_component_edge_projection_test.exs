defmodule CodeMySpec.Requirements.DiscoveredComponentEdgeProjectionTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, GraphInputs, Preloader, Projection, Shadow, ShadowProjector}
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup do
    previous_shadow = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    previous_source = Application.get_env(:code_my_spec, :graph_event_is_source, false)
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    Application.put_env(:code_my_spec, :graph_event_is_source, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :graph_shadow_projection, previous_shadow)
      Application.put_env(:code_my_spec, :graph_event_is_source, previous_source)
    end)

    %{scope: full_scope_fixture()}
  end

  @child_path "lib/example/accounts/user.ex"

  test "discovered child edges follow file membership at each checkout", %{scope: first} do
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

    # The discovered component is in the shared architecture, while its source
    # file initially exists in only the first checkout.
    file = insert_file(first, child.id)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    assert child_edge?(first, child.id)
    refute child_edge?(second, child.id)

    # A project-wide story observation must retain each checkout's distinct
    # file-backed topology.
    {:ok, _} =
      Stories.update_story(first, story, %{description: "The account user can be managed"})

    settle_both(first, second)
    assert_clean_projection(first)
    assert_clean_projection(second)

    # Removing and restoring the file changes only the first checkout's graph.
    Repo.delete!(file)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    refute child_edge?(first, child.id)
    refute child_edge?(second, child.id)
    assert_clean_projection(first)
    assert_clean_projection(second)

    insert_file(first, child.id)
    announce_file_membership(first, child.id)
    settle_both(first, second)

    assert child_edge?(first, child.id)
    refute child_edge?(second, child.id)
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
    {:ok, _pid} = ShadowProjector.ensure_projecting(first)

    :ok =
      ShadowProjector.settle(first.active_project_id, [
        first.active_working_copy_id,
        second.active_working_copy_id
      ])
  end

  defp child_edge?(scope, component_id) do
    ctx = Preloader.topology_context(scope)
    source = {Shadow.event_target(), {Shadow.event_edges(), Edge}}
    {_nodes, edges} = Projection.load(scope, ctx, source: source)

    Enum.any?(edges, fn edge ->
      match?({"story", _, _}, edge.from) and
        match?({"component", ^component_id, _}, edge.to)
    end)
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
