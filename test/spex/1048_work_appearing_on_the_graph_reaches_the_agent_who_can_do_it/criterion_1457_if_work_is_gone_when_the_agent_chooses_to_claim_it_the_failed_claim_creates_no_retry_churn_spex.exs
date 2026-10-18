defmodule CodeMySpecSpex.Story1048.Criterion3559Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3559 — Losing a claim race creates no task or retry churn.

  Graph work offers an unassigned turn, but another agent claims first through
  start_task. The losing caller must be refused, keeping the winner's task and
  the current turn intact, without sending a retry message or queueing a turn.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
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

  spex "An agent losing the claim race is refused without retry churn", criterion: 1457 do
    scenario "Another agent claims first after the work turn was offered" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3559")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3559 refund posting",
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
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)
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
          entity_id: to_string(context.story.number)
        }

        claimed =
          ToolLibrary.run(
            "start_task",
            claim,
            Map.put(winner_frame.assigns, :scope, winner_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, claimed), response_text(claimed)
        :ok = Fixtures.settle_graph(context.scope)

        winner_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(winner_frame.assigns, :scope, winner_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, winner_tasks), response_text(winner_tasks)
        assert response_text(winner_tasks) =~ "# Tasks (1)"

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           claim: claim,
           winner_frame: winner_frame,
           loser_frame: loser_frame,
           winner_tasks: response_text(winner_tasks),
           conversation_before: response_text(conversation)
         })}
      end

      when_ "the agent attempts to claim the now-owned requirement", context do
        result =
          ToolLibrary.run(
            "start_task",
            context.claim,
            Map.put(
              context.loser_frame.assigns,
              :scope,
              context.loser_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :claim_result, result)}
      end

      then_ "the losing claim is refused and only the winner owns a task", context do
        assert match?({:error, _}, context.claim_result), response_text(context.claim_result)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.loser_frame.assigns,
              :scope,
              context.loser_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == "No tasks."

        winner_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.winner_frame.assigns,
              :scope,
              context.winner_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, winner_tasks), response_text(winner_tasks)
        assert response_text(winner_tasks) == context.winner_tasks
        {:ok, context}
      end

      then_ "the refused claim creates no retry turn or message", context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end
