defmodule CodeMySpec.DeploysEnvironmentTest do
  @moduledoc """
  Whether an environment — or a server — is deployed.

  `deployed?/3` answers for one story. These answer for the set, which is the
  question the release gate and the status page actually ask: "is UAT up to
  date", "is anything running on that box".

  Environments are rows rather than a fixed prod/uat pair, and one server can
  carry more than one of them, so neither answer can be derived from a name.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Deploys
  alias CodeMySpec.Provisioning.EnvironmentRepository

  setup do
    scope = full_scope_fixture()
    EnvironmentRepository.list(scope)

    {:ok, scope: scope}
  end

  describe "environment_deployed?/2" do
    test "true only when every released story is on it", ctx do
      first = released_story(ctx.scope)
      second = released_story(ctx.scope)

      deploy(ctx.scope, first, "uat")

      refute Deploys.environment_deployed?(ctx.scope, "uat"),
             "one story of two is not an up-to-date environment"

      deploy(ctx.scope, second, "uat")

      assert Deploys.environment_deployed?(ctx.scope, "uat")
    end

    # The pace gate again: a parked story produces no requirement nodes, so
    # counting it here would hold an environment behind for work nobody started.
    test "a parked story does not hold the environment back", ctx do
      released = released_story(ctx.scope)
      _parked = parked_story(ctx.scope)

      deploy(ctx.scope, released, "uat")

      assert Deploys.environment_deployed?(ctx.scope, "uat")
    end

    test "a deploy that never answered does not count", ctx do
      story = released_story(ctx.scope)

      {:ok, _} = Deploys.record(ctx.scope, story.id, "uat", health_verified_at: nil)

      refute Deploys.environment_deployed?(ctx.scope, "uat")
    end

    test "a project with nothing released is not deployed", ctx do
      refute Deploys.environment_deployed?(ctx.scope, "uat"),
             "shipping nothing is not shipping"
    end
  end

  describe "server_deployed?/2" do
    # One box can carry both environments — setup starts them together and can
    # move production to its own later — so this is a question about whatever
    # points at the server, not about a name.
    test "true when every environment on the box is deployed", ctx do
      story = released_story(ctx.scope)

      {:ok, _} = EnvironmentRepository.put(ctx.scope, "uat", %{server_name: "box-1"})
      {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{server_name: "box-1"})

      deploy(ctx.scope, story, "uat")

      refute Deploys.server_deployed?(ctx.scope, "box-1"),
             "production also runs on this box and has not shipped"

      deploy(ctx.scope, story, "prod")

      assert Deploys.server_deployed?(ctx.scope, "box-1")
    end

    test "a box nothing runs on has nothing deployed to it", ctx do
      refute Deploys.server_deployed?(ctx.scope, "box-nobody-uses")
    end
  end

  describe "deployed_environments/1" do
    test "names the ones that are fully out", ctx do
      story = released_story(ctx.scope)

      deploy(ctx.scope, story, "uat")

      assert Deploys.deployed_environments(ctx.scope) == ["uat"]

      deploy(ctx.scope, story, "prod")

      assert Enum.sort(Deploys.deployed_environments(ctx.scope)) == ["prod", "uat"]
    end
  end

  defp released_story(scope) do
    CodeMySpec.StoriesFixtures.story_fixture(scope, %{
      title: "released #{System.unique_integer([:positive])}",
      ready_for_dev: true
    })
  end

  defp parked_story(scope) do
    CodeMySpec.StoriesFixtures.story_fixture(scope, %{
      title: "parked #{System.unique_integer([:positive])}",
      ready_for_dev: false
    })
  end

  defp deploy(scope, story, environment) do
    {:ok, _} =
      Deploys.record(scope, story.id, environment, health_verified_at: DateTime.utc_now())
  end
end
