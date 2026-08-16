defmodule CodeMySpec.Requirements.DeployedPredicateTest do
  @moduledoc """
  Deploy gates read the `deploys` table, and read it honestly.

  The vision these serve: a story that clears QA rides to UAT, and production
  goes out when the whole graph is green. Both are questions about deploys that
  actually answered, so both are answered from the row the deploy step writes —
  which it writes only on its success branch, after its own health probe passed.
  A flag on the story would be a second copy of that fact, free to drift from it
  after a partial or failed deploy.

  These assert the queries against a real database rather than their shape. A
  predicate that compiles and selects the wrong rows is the failure this is for.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Deploys
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Predicates

  setup do
    scope = full_scope_fixture()

    {:ok, scope: scope}
  end

  describe ":deployed" do
    test "a story with a health-verified deploy is satisfied", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, story.id, "uat", health_verified_at: DateTime.utc_now())

      assert story.id in satisfied_story_ids(:deployed, %{environment: "uat"})
    end

    # The whole reason this reads the table rather than a flag: a deploy that
    # shipped and never answered must not count (criterion 1964).
    test "a deploy that never passed its health check is not satisfied", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} = Deploys.record(ctx.scope, story.id, "uat", health_verified_at: nil)

      refute story.id in satisfied_story_ids(:deployed, %{environment: "uat"})
    end

    test "a deploy to another environment does not satisfy this one", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, story.id, "prod", health_verified_at: DateTime.utc_now())

      refute story.id in satisfied_story_ids(:deployed, %{environment: "uat"})
      assert story.id in satisfied_story_ids(:deployed, %{environment: "prod"})
    end

    test "a story with no deploy at all is not satisfied", ctx do
      story = story_with_node(ctx.scope)

      refute story.id in satisfied_story_ids(:deployed, %{environment: "uat"})
    end
  end

  describe ":all_deployed" do
    test "satisfied only when every story is out", ctx do
      project_node(ctx.scope)
      first = story_with_node(ctx.scope)
      second = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, first.id, "prod", health_verified_at: DateTime.utc_now())

      refute any_satisfied?(:all_deployed, %{environment: "prod"}),
             "one story out of two is not a release"

      {:ok, _} =
        Deploys.record(ctx.scope, second.id, "prod", health_verified_at: DateTime.utc_now())

      assert any_satisfied?(:all_deployed, %{environment: "prod"})
    end

    # A story added after a release un-satisfies it again, which is what makes
    # this a gate rather than a latch.
    test "a story added afterwards un-satisfies it", ctx do
      project_node(ctx.scope)
      first = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, first.id, "prod", health_verified_at: DateTime.utc_now())

      assert any_satisfied?(:all_deployed, %{environment: "prod"})

      _late = story_with_node(ctx.scope)

      refute any_satisfied?(:all_deployed, %{environment: "prod"}),
             "a story that has never shipped left the release reading done"
    end

    # Releasing nothing is not a release.
    test "a project with no stories is not satisfied", ctx do
      project_node(ctx.scope)

      refute any_satisfied?(:all_deployed, %{environment: "prod"})
    end
  end

  # A node's owner is whichever of component_id / story_id / project_id is set —
  # the unique indexes are partial on exactly that. Setting two makes the row
  # answer to both, and the second story then collides on the project index.
  defp story_with_node(scope) do
    story =
      CodeMySpec.StoriesFixtures.story_fixture(scope, %{
        title: "deploy gate #{System.unique_integer([:positive])}"
      })

    Repo.insert!(%Node{
      story_id: story.id,
      name: "uat_deployed",
      description: "the story is live on this environment",
      satisfied: false
    })

    story
  end

  defp project_node(scope) do
    Repo.insert!(%Node{
      project_id: scope.active_project_id,
      name: "prod_released",
      description: "every story is live on production",
      satisfied: false
    })
  end

  defp satisfied_story_ids(check, config) do
    Node
    |> from(as: :node)
    |> Predicates.satisfied(check, config)
    |> select([node: n], n.story_id)
    |> Repo.all()
  end

  defp any_satisfied?(check, config) do
    Node
    |> from(as: :node)
    |> Predicates.satisfied(check, config)
    |> Repo.aggregate(:count) > 0
  end
end
