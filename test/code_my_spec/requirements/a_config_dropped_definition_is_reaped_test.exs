defmodule CodeMySpec.Requirements.AConfigDroppedDefinitionIsReapedTest do
  @moduledoc """
  A definition the config stops producing leaves no row behind, in either
  writer. `deploy` under a legacy nil `devops` is the case (v2.0.177).
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{ready_for_dev: true})
    set_devops(scope, :prod)
    %{scope: scope, story: story}
  end

  test "a story recompute on the event path reaps deploy once devops is nil", ctx do
    event_write(ctx.scope, ctx.story)
    assert "deploy" in names(GraphStore.event_target(), ctx.story.id)

    set_devops(ctx.scope, nil)
    {:ok, %{reaped: reaped}} = event_write(ctx.scope, ctx.story)

    refute "deploy" in names(GraphStore.event_target(), ctx.story.id)
    assert reaped >= 1
  end

  test "a vantage holding deploy under nil devops is not established, so it reseeds", ctx do
    event_write(ctx.scope, ctx.story)
    assert GraphStore.definitions_covered?(ctx.scope, defined(ctx.scope))

    set_devops(ctx.scope, nil)
    refute GraphStore.definitions_covered?(ctx.scope, defined(ctx.scope))
  end

  defp event_write(scope, story) do
    {:ok, loaded} = Preloader.load(scope)
    config = Configurations.get_or_create(scope)
    {covered, nodes} = RequirementGraph.compute_entity(scope, loaded, config, {"story", story.id})
    GraphStore.write(scope, covered, nodes)
  end

  defp defined(scope),
    do:
      RequirementGraph.defined_names(
        Preloader.topology_context(scope),
        Configurations.get_or_create(scope)
      )

  # Straight to the column: nil is the legacy row no changeset produces.
  defp set_devops(scope, level) do
    Configurations.get_or_create(scope)

    ProjectConfiguration
    |> where([c], c.project_id == ^scope.active_project_id)
    |> Repo.update_all(set: [devops: level])
  end

  defp names(target, story_id) do
    target
    |> where([n], n.story_id == ^story_id)
    |> select([n], n.name)
    |> Repo.all()
  end
end
