defmodule CodeMySpecSpex.Story1048.Criterion3557Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3557 — A failed graph recompute requests no turn.

  Inject the existing project-scoped graph fault before releasing work.
  Assert the expected failure was actually logged; no error unrelated to the
  injected failure is cleared. Real engine and task surfaces prove silence.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

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

  spex "A failed recompute cannot authorize a work turn", criterion: 1455 do
    scenario "Failure to compute eligibility leaves the existing agent idle" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3557")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before coding work is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3557 refund posting",
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

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: agent.id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           story: story,
           conversation_before: response_text(conversation),
           history_before: Machine.history(agent.id),
           roster_before: Enum.sort(Machine.running())
         })}
      end

      when_ "releasing the story encounters a failed recompute", context do
        :ok = Fixtures.break_graph_recompute(context.scope)
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        assert Fixtures.graph_last_error(context.scope) =~ "fault injected for this project"
        Fixtures.stop_graph_watchers()
        SexySpex.ErrorCapture.clear()
        {:ok, context}
      end

      then_ "the existing coding agent receives neither a turn nor a message", context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert Machine.running?(context.agent_id)
        assert HeldProvider.seen() == []
        assert Enum.sort(Machine.running()) == context.roster_before

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
