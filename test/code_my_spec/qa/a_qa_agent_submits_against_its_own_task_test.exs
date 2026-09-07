defmodule CodeMySpec.Qa.AQaAgentSubmitsAgainstItsOwnTaskTest do
  @moduledoc """
  A QA agent we run holds its own task, and submitting had to find it.

  `resolve_task_info/2` searched `Session.tasks` and nothing else. An agent
  under Alloy keeps its tasks on the agent row — that is what `TaskOwner`
  exists for — so a real task id came back `task_not_found`, the honest answer
  to the wrong question.

  Watched on the war-epic copy, 2026-09-06: "QA is blocked: the required result
  submission returns `task_not_found` because this conversation has no
  registered session." The agent's diagnosis was right and the remedy it
  inferred — register a session — is not something it can do. So it stopped,
  was nudged about the still-open `qa_complete`, and repeated for an hour
  without submitting anything.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        working_copy: "/tmp/qa-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    task_id = Ecto.UUID.generate()

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        id: task_id,
        status: :active,
        requirement_name: "qa_complete",
        story_id: story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    %{scope: scope, story: story, agent: agent, task_id: task_id}
  end

  defp attrs(task_id, status) do
    %{
      task_id: task_id,
      status: status,
      scenarios: [
        %{
          "name" => "the city falls",
          "status" => "pass",
          "observation" => "the capital changed hands and the realm became a vassal"
        }
      ]
    }
  end

  test "the attempt lands against a task held by the agent", ctx do
    assert {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    assert attempt.task_id == ctx.task_id
    assert attempt.story_id == ctx.story.id
  end

  # The story comes off the task, not off the submission — a QA agent that had
  # to state it could state the wrong one, and nothing in the payload would say
  # so. `:pass` rather than `:fail` because a failure has to cite issue ids,
  # which is a different rule and not the one under test here.
  test "the story is taken from the task, not from the caller", ctx do
    {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    assert attempt.story_id == ctx.story.id
    refute Map.has_key?(attrs(ctx.task_id, :pass), :story_id)
  end

  # The refusal still has to work. A task id belonging to nothing is not the
  # same as one this could not look in the right place for.
  test "an id that is on neither an agent nor a session is refused", ctx do
    assert {:error, :task_not_found} =
             Qa.submit_qa_result(ctx.scope, attrs(Ecto.UUID.generate(), :pass))
  end
end
