defmodule CodeMySpecSpex.Story538.Criterion1498Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1498 — Repeated failures do not silently terminate durable continuous intent.

  Five real evaluations encounter the same missing specification files. The
  subsequent stop decision must surface the repetition while preserving the
  active attempt and the user's continuous-work intent.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    exunit_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Repeated failed evaluations preserve deliberate continuous intent", criterion: 106 do
    scenario "Five identical failures are surfaced without cancelling or replacing the task" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_1498")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous agent owns a specification task whose files have not been written",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Keep working after failed evaluation",
            description: "Evaluation feedback must preserve the current attempt",
            acceptance_criteria: ["The agent retains the task when its specs are missing"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            agent_frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, tasks, _} = ListTasks.execute(%{}, agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ task_id

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           task_id: task_id,
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent explicitly evaluates the same unfinished task five times", context do
        evaluations =
          Enum.map(1..5, fn _ ->
            {:reply, response, _} =
              EvaluateTask.execute(%{task_id: context.task_id}, context.agent_frame)

            refute response.isError, response_text(response)
            assert response_text(response) =~ "Needs work"
            response_text(response)
          end)

        assert length(Enum.uniq(evaluations)) == 1
        {:ok, Map.put(context, :evaluations, evaluations)}
      end

      then_ "the same task stays active and no new task or automatic model turn is admitted",
            context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end

      when_ "the agent reports the end of its turn", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "continuous remains enabled and the original attempt is still the only task",
            context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "the latest stop feedback identifies the active task and its repeated failure",
            context do
        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id, limit: 1}, frame(context))

        refute conversation.isError, response_text(conversation)
        text = response_text(conversation)
        assert text =~ context.task_id
        assert text =~ ~r/repeat|same feedback|same failure|five.*fail|5.*fail/i
        refute text =~ "Task completed successfully"
        {:ok, context}
      end
    end
  end
end
