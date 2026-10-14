defmodule CodeMySpec.Requirements.DeployedPredicateTest do
  @moduledoc """
  Deploy gates read the `deploys` table, and read it honestly.

  The vision these serve: a story that clears QA rides to UAT, and production
  goes out when the whole graph is green. Both are questions about deploys that
  actually answered, so both are answered from the row the deploy step writes —
  which it writes only on its success branch, after its own health probe passed.
  A flag on the story would be a second copy of that fact, free to drift from it
  after a partial or failed deploy.

  These ask `RequirementCalculator`, the check the graph runs, against a real
  database.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Deploys
  alias CodeMySpec.Requirements.RequirementCalculator

  setup do
    scope = full_scope_fixture()

    {:ok, scope: scope}
  end

  describe ":deployed" do
    test "a story with a health-verified deploy is satisfied", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, story.id, "uat", health_verified_at: DateTime.utc_now())

      assert deployed?(ctx.scope, story, "uat")
    end

    # The whole reason this reads the table rather than a flag: a deploy that
    # shipped and never answered must not count (criterion 1964).
    test "a deploy that never passed its health check is not satisfied", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} = Deploys.record(ctx.scope, story.id, "uat", health_verified_at: nil)

      refute deployed?(ctx.scope, story, "uat")
    end

    test "a deploy to another environment does not satisfy this one", ctx do
      story = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, story.id, "prod", health_verified_at: DateTime.utc_now())

      refute deployed?(ctx.scope, story, "uat")
      assert deployed?(ctx.scope, story, "prod")
    end

    test "a story with no deploy at all is not satisfied", ctx do
      story = story_with_node(ctx.scope)

      refute deployed?(ctx.scope, story, "uat")
    end
  end

  describe ":all_deployed" do
    test "satisfied only when every story is out", ctx do
      first = story_with_node(ctx.scope)
      second = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, first.id, "prod", health_verified_at: DateTime.utc_now())

      refute all_deployed?(ctx.scope, "prod"),
             "one story out of two is not a release"

      {:ok, _} =
        Deploys.record(ctx.scope, second.id, "prod", health_verified_at: DateTime.utc_now())

      assert all_deployed?(ctx.scope, "prod")
    end

    # A story added after a release un-satisfies it again, which is what makes
    # this a gate rather than a latch.
    test "a story added afterwards un-satisfies it", ctx do
      first = story_with_node(ctx.scope)

      {:ok, _} =
        Deploys.record(ctx.scope, first.id, "prod", health_verified_at: DateTime.utc_now())

      assert all_deployed?(ctx.scope, "prod")

      _late = story_with_node(ctx.scope)

      refute all_deployed?(ctx.scope, "prod"),
             "a story that has never shipped left the release reading done"
    end

    # Releasing nothing is not a release.
    test "a project with no stories is not satisfied", ctx do
      refute all_deployed?(ctx.scope, "prod")
    end
  end

  defp story_with_node(scope) do
    CodeMySpec.StoriesFixtures.story_fixture(scope, %{
      title: "deploy gate #{System.unique_integer([:positive])}"
    })
  end

  # The check the graph runs, asked directly.
  defp deployed?(scope, story, environment),
    do: satisfied?(scope, story, :deployed, environment)

  defp all_deployed?(scope, environment),
    do: satisfied?(scope, scope.active_project, :all_deployed, environment)

  defp satisfied?(scope, entity, check_type, environment) do
    definition = %{
      name: "deploy_gate",
      check_type: check_type,
      config: %{environment: environment}
    }

    RequirementCalculator.compute_one(scope, entity, definition, []).satisfied
  end
end
