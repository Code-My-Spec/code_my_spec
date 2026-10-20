defmodule CodeMySpec.Hooks.AQueuedPromotionDoesNotTripStuckDetectionTest do
  @moduledoc """
  Issue 963996d9: a continuous coder that had queued its promotion stopped
  repeatedly while the queue gated it. Each stop was evaluated, got the same
  "not landed yet" feedback, and R8 stuck-detection turned continuous off after
  five — three times on 2026-10-20, each leaving the agent idle until someone
  switched it back on.

  Waiting on a landing is progress the agent cannot speed up. While the queue
  holds its promotion a stop is allowed without being evaluated or counted;
  the same repeated stops with nothing queued still trip R8.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "promoting",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id, cwd: nil}
    story = story_fixture(scope)

    agent =
      terminal_agent_fixture(scope, %{
        role: :coding,
        continuous: true,
        tasks: [
          %{
            status: :active,
            requirement_name: "story_promoted",
            session_type: CodeMySpec.AgentTasks.PromoteWork,
            story_id: story.id,
            project_id: scope.active_project_id,
            started_at: DateTime.utc_now(),
            # Five identical "not landed yet" failures already counted: the
            # threshold R8 fires at.
            evaluation_feedback: "not landed yet",
            evaluation_feedback_count: 5
          }
        ]
      })

    %{scope: scope, copy: copy, story: story, agent: agent}
  end

  defp queue(ctx, status) do
    {:ok, entry} =
      %{
        project_id: ctx.scope.active_project_id,
        working_copy_id: ctx.copy.id,
        commit: String.duplicate("a", 40),
        subject_type: :story,
        subject_id: to_string(ctx.story.number),
        requested_by_agent_id: ctx.agent.id,
        restart: false
      }
      |> Entry.enqueue_changeset()
      |> Repo.insert()

    entry |> Entry.status_changeset(%{status: status}) |> Repo.update!()
  end

  defp stop(ctx), do: Stop.decide(ctx.scope, %{"session_id" => ctx.agent.engine_session_id})
  defp reload(ctx), do: Repo.get!(Agent, ctx.agent.id)

  for status <- [:queued, :gating] do
    @status status
    test "repeated stops while the promotion is #{status} stay continuous and uncounted", ctx do
      queue(ctx, @status)
      before = Agent.active_task(reload(ctx)).evaluation_feedback_count
      assert before == 5

      for _ <- 1..8 do
        response = stop(ctx)
        refute response["decision"] == "block", inspect(response)
        assert String.downcase(Jason.encode!(response)) =~ "queued"
      end

      agent = reload(ctx)
      assert agent.continuous
      assert Agent.active_task(agent).evaluation_feedback_count == before
    end
  end

  test "the same repeated stops with nothing queued still trip stuck-detection", ctx do
    # At the threshold with nothing queued, the next stop ends continuous mode.
    stop(ctx)

    refute reload(ctx).continuous
  end
end
