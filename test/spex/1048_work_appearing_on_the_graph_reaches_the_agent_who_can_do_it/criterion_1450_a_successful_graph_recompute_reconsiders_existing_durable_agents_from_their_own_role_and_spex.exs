defmodule CodeMySpecSpex.Story1048.Criterion3552Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3552 — Graph recomputation respects each agent's role and copy.

  Durable agent rows are fixture setup; real engines and a held local provider
  observe delivery. Releasing the story drives the real graph watcher, without
  toggling continuous or directly requesting a turn.
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

  spex "Graph changes reconsider existing agents in their own scope", criterion: 1450 do
    scenario "Releasing coding work reaches only its assigned coding agent" do
      given_ "two connected checkouts share a project", context do
        # The kicked-off checkout is created *last*, because
        # `given_a_staffed_checkout/2` designates its copy as the project's
        # main one and the last call wins. Built the other way round, the
        # kickoff artifacts landed on a copy the project no longer called main,
        # `technical_strategy` stayed open at the first vantage, and the serial
        # chain clamped `bdd_specs_exist` — so releasing the story made nothing
        # actionable for coding and the turn this criterion is about was
        # correctly never requested.
        second = given_a_staffed_checkout(context, "spex_3552_second")
        first = given_a_staffed_checkout(context, "spex_3552_first")
        first = ProjectStateFixtures.apply_project_kickoff(first)
        {:ok, Map.put(first, :second, second)}
      end

      given_ :synced_context_component

      given_ "an unreleased story and three idle continuous agents", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Coding work belongs to the first checkout",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        epic = Fixtures.epic_fixture(context.scope)
        :ok = Fixtures.put_story_in_epic(context.scope, story, epic)

        assigned =
          ToolLibrary.run(
            "assign_epic_to_working_copy",
            %{epic_id: to_string(epic.id), working_copy_id: context.copy_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, assigned), response_text(assigned)
        :ok = Fixtures.watch_graph(context.scope)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        other = Fixtures.running_agent(context.second.scope, role: "coding", continuous: true)
        agents = [{coding, context}, {qa, context}, {other, context.second}]
        base_url = HeldProvider.start()
        HeldProvider.hold()

        conversations =
          Map.new(agents, fn {agent, copy} ->
            assert Fixtures.role_queue_size(copy.scope, agent.id) == 0
            assert {:ok, _} = Machine.start_agent(agent.id, copy.copy, base_url: base_url)
            on_exit(fn -> Machine.stop_agent(agent.id) end)

            conversation =
              ToolLibrary.run(
                "read_agent_conversation",
                %{agent_id: agent.id},
                Map.put(frame(copy).assigns, :scope, frame(copy).assigns[:current_scope])
              )

            assert match?({:ok, _}, conversation), response_text(conversation)
            {agent.id, response_text(conversation)}
          end)

        {:ok,
         Map.merge(context, %{
           story: story,
           coding_id: coding.id,
           agents: agents,
           conversations: conversations
         })}
      end

      when_ "the story is released and the graph recomputes", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "only the eligible coding agent receives one unassigned turn", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.coding_id)

        for {agent, copy} <- context.agents, agent.id != context.coding_id do
          conversation =
            ToolLibrary.run(
              "read_agent_conversation",
              %{agent_id: agent.id},
              Map.put(frame(copy).assigns, :scope, frame(copy).assigns[:current_scope])
            )

          assert match?({:ok, _}, conversation), response_text(conversation)
          assert response_text(conversation) == context.conversations[agent.id]
          assert {:ok, %{busy?: false}} = Machine.status(agent.id)
        end

        for {agent, copy} <- context.agents do
          tasks =
            ToolLibrary.run(
              "list_tasks",
              %{agent_id: agent.id},
              Map.put(frame(copy).assigns, :scope, frame(copy).assigns[:current_scope])
            )

          assert match?({:ok, _}, tasks), response_text(tasks)
          assert response_text(tasks) =~ "No tasks"
        end

        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end
