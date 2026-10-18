defmodule CodeMySpecSpex.Story1047.Criterion3565Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3565 — Working-copy eligibility is isolated.

  Two real coding engines share a project, but only one checkout owns the
  story. The positive turn and the negative conversation assertion distinguish
  copy scoping from role-only routing.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
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

  spex "Eligible work belongs to its assigned working copy", criterion: 1463 do
    scenario "Only the coding agent on the assigned checkout receives a turn" do
      given_ "the project has two connected checkouts", context do
        first = given_a_staffed_checkout(context, "spex_3565_first")
        second = given_a_staffed_checkout(context, "spex_3565_second")
        first = ProjectStateFixtures.apply_project_kickoff(first)
        {:ok, Map.put(first, :second, second)}
      end

      given_ :synced_context_component

      given_ "a ready story belongs exclusively to the first checkout", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "First checkout only",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: true
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        epic = Fixtures.epic_fixture(context.scope)
        :ok = Fixtures.put_story_in_epic(context.scope, story, epic)

        {:reply, assigned, _} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: to_string(epic.id), working_copy_id: context.copy_id},
            frame(context)
          )

        refute assigned.isError, response_text(assigned)

        first = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        second = Fixtures.running_agent(context.second.scope, role: "coding", continuous: true)

        for copy <- [context, context.second] do
          graph =
            ToolLibrary.run(
              "get_next_requirement",
              %{},
              Map.put(frame(copy).assigns, :scope, frame(copy).assigns[:current_scope])
            )

          assert match?({:ok, _}, graph), response_text(graph)
        end

        assert Fixtures.role_queue_size(context.scope, first.id) > 0
        assert Fixtures.role_queue_size(context.second.scope, second.id) == 0

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for {agent, path} <- [{first, context.copy}, {second, context.second.copy}] do
          assert {:ok, _} = Machine.start_agent(agent.id, path, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(agent.id) end)
        end

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: second.id},
            Map.put(
              frame(context.second).assigns,
              :scope,
              frame(context.second).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           first_id: first.id,
           second_id: second.id,
           second_conversation: response_text(conversation)
         })}
      end

      when_ "eligibility is reconsidered for both coding agents", context do
        for {id, copy} <- [{context.first_id, context}, {context.second_id, context.second}] do
          response =
            ToolLibrary.run(
              "set_agent_continuous",
              %{agent_id: id, continuous: true},
              Map.put(frame(copy).assigns, :scope, frame(copy).assigns[:current_scope])
            )

          assert match?({:ok, _}, response), response_text(response)
        end

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "only the assigned checkout's agent takes a turn", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.first_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.second_id)
        assert length(HeldProvider.seen()) == 1

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.second_id},
            Map.put(
              frame(context.second).assigns,
              :scope,
              frame(context.second).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.second_conversation
        {:ok, context}
      end
    end
  end
end
