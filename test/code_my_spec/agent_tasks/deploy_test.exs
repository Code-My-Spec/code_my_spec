defmodule CodeMySpec.AgentTasks.DeployTest do
  @moduledoc """
  Whether a story's UAT deploy reads as done.

  `evaluate/2` used to read `.code_my_spec/devops/deploys/story_<id>.md` and
  grep it for "verified" — a file the agent wrote for itself, which the
  requirement graph's own `check_type: :deployed` check (`Deploys.deployed?/3`)
  never read at all. The two paths could disagree: a real deploy recorded by
  `Provisioning.Steps.deploy_environment/3` satisfied the graph but not this
  task's own `evaluate_task`, and nothing an agent did by hand could write
  the file in a way the graph would ever notice either. This checks both
  entity shapes read the same `deploys` row the graph does.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Deploy
  alias CodeMySpec.Deploys
  alias CodeMySpec.StoriesFixtures

  setup do
    scope = full_scope_fixture()
    story = StoriesFixtures.story_fixture(scope)

    {:ok, scope: scope, story: story}
  end

  describe "evaluate/2 — task-evaluator shape" do
    test "invalid when the story has no deploy at all", %{scope: scope, story: story} do
      assert {:ok, :invalid, message} = Deploy.evaluate(scope, %{story_id: story.id})
      assert message =~ "#{story.id}"
    end

    test "invalid when the deploy exists but never health-verified", %{
      scope: scope,
      story: story
    } do
      {:ok, _} = Deploys.record(scope, story.id, "uat")

      assert {:ok, :invalid, _message} = Deploy.evaluate(scope, %{story_id: story.id})
    end

    test "valid once the deploy is health-verified", %{scope: scope, story: story} do
      {:ok, _} = Deploys.record(scope, story.id, "uat", health_verified_at: DateTime.utc_now())

      assert {:ok, :valid} = Deploy.evaluate(scope, %{story_id: story.id})
    end

    test "a prod-only deploy does not satisfy the UAT check", %{scope: scope, story: story} do
      {:ok, _} = Deploys.record(scope, story.id, "prod", health_verified_at: DateTime.utc_now())

      assert {:ok, :invalid, _message} = Deploy.evaluate(scope, %{story_id: story.id})
    end

    test "invalid without a story to check", %{scope: scope} do
      assert {:ok, :invalid, _message} = Deploy.evaluate(scope, %{})
    end
  end

  describe "evaluate/2 — requirement-delegate shape (a Story struct)" do
    test "reads the same row as the task-evaluator shape", %{scope: scope, story: story} do
      {:ok, _} = Deploys.record(scope, story.id, "uat", health_verified_at: DateTime.utc_now())

      assert {:ok, :valid} = Deploy.evaluate(scope, story)
    end
  end

  describe "command/2" do
    test "does not ask the agent to write a deploy record file", %{scope: scope, story: story} do
      {:ok, prompt} = Deploy.command(scope, %{story_id: story.id})

      refute prompt =~ ".md",
             "the deploy is recorded by the deploy step itself now — nothing left to write by hand"
    end
  end
end
