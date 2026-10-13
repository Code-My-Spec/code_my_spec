defmodule CodeMySpec.Agents.PromotionNoticeRoutingTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Events
  alias CodeMySpec.Conversations
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()
    RecordingAgentTransport.listen(scope)
    copy_id = CodeMySpec.WorkingCopies.ensure_default(scope)
    scope = %{scope | active_working_copy_id: copy_id}

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "zai",
        role: :coding,
        working_copy: "/tmp/notice-test",
        working_copy_id: copy_id,
        status: :running
      })

    CodeMySpecTest.AgentPresence.present(agent)
    %{scope: scope, agent: agent}
  end

  defp report(ctx, what) do
    Events.handle_event(
      [:code_my_spec, :promotion, :report],
      %{},
      %{scope: ctx.scope, agent_id: ctx.agent.id, text: what, what: what},
      nil
    )
  end

  test "confirmation without an open promotion task is suppressed", ctx do
    report(ctx, "restart confirmation")
    refute_received {:agent_dispatch, _, _, _}
  end

  for status <- [:active, :prepared, :blocked] do
    @status status
    test "confirmation reaches a #{@status} promotion task", ctx do
      story = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope)

      {:ok, _} =
        TaskOwner.add_task(ctx.scope, ctx.agent, %{
          status: @status,
          requirement_name: "story_promoted",
          story_id: story.id
        })

      report(ctx, "restart confirmation")
      id = ctx.agent.id
      assert_received {:agent_dispatch, ^id, ref, "restart confirmation"}

      assert %{sender_id: "promotion-notice", delivery: :pending} =
               CodeMySpec.Repo.get_by(Conversations.Message,
                 delivery_ref: ref,
                 delivery: :pending
               )
    end
  end

  test "a completed promotion task does not receive another confirmation", ctx do
    story = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope)

    {:ok, _} =
      TaskOwner.add_task(ctx.scope, ctx.agent, %{
        status: :completed,
        requirement_name: "story_promoted",
        story_id: story.id
      })

    report(ctx, "restart confirmation")
    refute_received {:agent_dispatch, _, _, _}
  end

  test "failures still reach an agent with no promotion task", ctx do
    report(ctx, "restart failure")
    id = ctx.agent.id
    assert_received {:agent_dispatch, ^id, ref, "restart failure"}

    assert %{sender_id: "operator"} =
             CodeMySpec.Repo.get_by(Conversations.Message, delivery_ref: ref, delivery: :pending)
  end
end
