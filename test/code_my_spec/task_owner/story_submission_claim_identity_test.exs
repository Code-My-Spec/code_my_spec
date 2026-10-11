defmodule CodeMySpec.TaskOwner.StorySubmissionClaimIdentityTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.AgentTasks.SubmitStoryIssue
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  test "two coders can own distinct issue submissions in the same story but cannot claim the same issue" do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    agents =
      for _ <- 1..3 do
        {:ok, agent} =
          AgentsRepository.create_agent(scope, %{
            engine: :alloy,
            provider: "zai",
            role: :coding,
            status: :running,
            working_copy: "/tmp/submission-identity",
            working_copy_id: copy.id,
            story_id: story.id
          })

        agent
      end

    [first, second, duplicate] = agents

    attrs = %{
      id: Ecto.UUID.generate(),
      requirement_name: "submitted",
      status: :active,
      session_type: SubmitStoryIssue,
      story_id: story.id,
      issue_id: Ecto.UUID.generate(),
      project_id: scope.active_project_id
    }

    assert {:ok, _} = TaskOwner.add_task(scope, first, attrs)

    assert {:ok, _} =
             TaskOwner.add_task(scope, second, %{
               attrs
               | id: Ecto.UUID.generate(),
                 issue_id: Ecto.UUID.generate()
             })

    assert {:error, :task_owned_by_another_agent} =
             TaskOwner.add_task(scope, duplicate, %{attrs | id: Ecto.UUID.generate()})
  end
end
