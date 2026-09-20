defmodule CodeMySpecSpex.Story1048.Criterion3571Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3571 — Repeated failed claims do not churn.

  After another agent claims first, repeated explicit claim attempts remain
  refusals. Neither an alternate task nor a model turn is manufactured to
  compensate, and the winner retains its original task.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent losing the claim race is refused without retry churn" do
    scenario "Repeated attempts on already-owned work do not manufacture tasks or turns" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3571")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3571 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.watch_graph(context.scope)
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
        {:ok, Map.merge(context, %{agent_id: agent.id, story: story})}
      end

      given_ "the graph offers a turn but another agent claims the work first", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        other = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        winner_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: other.id}}
        loser_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        # `bdd_specs_exist` on the story, not `review_file` on the component:
        # `5662b2f6e` simplified component requirements to implementation work
        # alone, so `review_file` names no node on the graph.
        claim = %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(context.story.id)
        }

        {:reply, claimed, _} = StartTask.execute(claim, winner_frame)
        refute claimed.isError, response_text(claimed)
        :ok = Fixtures.settle_graph(context.scope)
        {:reply, winner_tasks, _} = ListTasks.execute(%{}, winner_frame)
        refute winner_tasks.isError, response_text(winner_tasks)
        assert response_text(winner_tasks) =~ "# Tasks (1)"

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           claim: claim,
           winner_frame: winner_frame,
           loser_frame: loser_frame,
           winner_tasks: response_text(winner_tasks),
           conversation_before: response_text(conversation)
         })}
      end

      when_ "the agent repeatedly tries to claim the already-owned requirement", context do
        results =
          for _ <- 1..3 do
            {:reply, result, _} = StartTask.execute(context.claim, context.loser_frame)
            result
          end

        {:ok, Map.put(context, :claim_results, results)}
      end

      then_ "the losing claim is refused and only the winner owns a task", context do
        for result <- context.claim_results do
          assert result.isError, response_text(result)
        end

        {:reply, tasks, _} = ListTasks.execute(%{}, context.loser_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:reply, winner_tasks, _} = ListTasks.execute(%{}, context.winner_frame)
        refute winner_tasks.isError, response_text(winner_tasks)
        assert response_text(winner_tasks) == context.winner_tasks
        {:ok, context}
      end

      then_ "the refused claim creates no retry turn or message", context do
        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end
