defmodule CodeMySpecSpex.Story1053.Criterion3268Spex do
  @moduledoc """
  Operational clarification does not replace the coding question or its task.
  Both questions are created through MCP, and the nested question is escalated
  through the same surface used by main. Unrelated work remains claimable.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
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

  spex "Nested operational questions preserve the original coding task", criterion: 1238 do
    scenario "Main asks the user for context while coding can claim unrelated work" do
      given_ "a connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3268")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "coding owns a task and another reviewed story is available", context do
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        {coding, task} = Fixtures.agent_task_fixture(context.scope, coding)

        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Receipt layout independent of deployment",
            description: "Independent coding work while the deployment question is pending",
            acceptance_criteria: ["The receipt layout is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for agent <- [main, coding] do
          assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(agent.id) end)
          assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
        end

        {:ok,
         Map.merge(context, %{
           coding_id: coding.id,
           main_id: main.id,
           coding_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}},
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           task_id: task.id,
           other_story: story,
           running_ids: Machine.running()
         })}
      end

      when_ "coding asks its technical question and main escalates an operational follow-up",
            context do
        {:reply, original, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              questions: [
                %{
                  question: "Which deployment credentials should this task use?",
                  options: [%{label: "Production"}, %{label: "Staging"}]
                }
              ]
            },
            context.coding_frame
          )

        refute original.isError, response_text(original)
        original_id = Fixtures.question_id_from(response_text(original))

        {:reply, nested, _} =
          AskUserQuestion.execute(
            %{
              task_id: nil,
              questions: [
                %{
                  question: "For question #{original_id}, which account does the customer own?",
                  options: [%{label: "Primary"}, %{label: "Secondary"}]
                }
              ]
            },
            context.main_frame
          )

        refute nested.isError, response_text(nested)
        nested_id = Fixtures.question_id_from(response_text(nested))

        {:reply, escalated, _} =
          EscalateQuestion.execute(
            %{
              question_id: nested_id,
              reason: "The customer account determines the credentials for #{original_id}"
            },
            context.main_frame
          )

        refute escalated.isError, response_text(escalated)
        {:ok, Map.merge(context, %{original_id: original_id, nested_id: nested_id})}
      end

      then_ "the nested question waits on the user and the original retains its owner and task",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.original_id
        assert response_text(inbox) =~ context.nested_id
        assert response_text(inbox) =~ ~r/waiting on the user/i
        assert response_text(inbox) =~ context.coding_id
        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.coding_frame)
        refute questions.isError, response_text(questions)
        assert response_text(questions) =~ context.original_id
        assert response_text(questions) =~ context.task_id
        refute response_text(questions) =~ context.nested_id
        {:reply, blocked, _} = ListTasks.execute(%{status: "blocked"}, context.coding_frame)
        refute blocked.isError, response_text(blocked)
        assert response_text(blocked) =~ context.task_id
        assert Machine.running() == context.running_ids

        for id <- [context.main_id, context.coding_id] do
          assert {:ok, %{busy?: false, queued: 0}} = Machine.status(id)
        end

        assert HeldProvider.seen() == []
        {:ok, context}
      end

      when_ "coding deliberately claims the unrelated story", context do
        {:reply, started, _} =
          StartTask.execute(
            %{
              entity_type: "story",
              entity_id: to_string(context.other_story.number),
              requirement_name: "bdd_specs_exist"
            },
            context.coding_frame
          )

        refute started.isError, response_text(started)
        {:ok, Map.put(context, :other_task_id, extract_task_id!(started))}
      end

      then_ "only the new task is active and the original remains blocked", context do
        assert context.other_task_id != context.task_id
        {:reply, active, _} = ListTasks.execute(%{status: "active"}, context.coding_frame)
        refute active.isError, response_text(active)
        assert response_text(active) =~ context.other_task_id
        refute response_text(active) =~ context.task_id
        {:reply, blocked, _} = ListTasks.execute(%{status: "blocked"}, context.coding_frame)
        refute blocked.isError, response_text(blocked)
        assert response_text(blocked) =~ context.task_id
        {:ok, context}
      end
    end
  end
end
