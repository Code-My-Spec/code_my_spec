defmodule CodeMySpecSpex.Story1017.Criterion2414Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2414 — An unanswered task question leaves unrelated work available.

  The agent claims a story's task, asks against it, ends its turn through the
  harness event contract, and explicitly claims unrelated component work. Not
  another story: the team sees its story through together (a31f1cd6). No blocker is pre-seeded.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
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

  spex "A task question does not block the agent's other work", criterion: 907 do
    scenario "The agent ends its turn and chooses another task while the question stays open" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two released stories need specs and the agent has claimed the first", context do
        [first, second] =
          Enum.map(["Refund policy", "Receipt formatting"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "An independent story for the question-blocking contract",
                acceptance_criteria: ["The stated behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            story
          end)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.number)
            },
            frame
          )

        refute started.isError, response_text(started)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: frame,
           task_id: extract_task_id!(started),
           second_story: second,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent asks a question linked to its active task", context do
        {:reply, response, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              questions: [
                %{
                  question: "Which refund period applies?",
                  options: [%{label: "14 days"}, %{label: "30 days"}]
                }
              ]
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "only the linked task is blocked and its question is still open", context do
        refute context.response.isError, response_text(context.response)

        [_, question_id] =
          Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(context.response))

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the harness can end the turn without answering the question", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:reply, work, _} = ListAgentWork.execute(%{}, context.agent_frame)
        refute work.isError, response_text(work)
        assert response_text(work) =~ context.agent_id
        assert response_text(work) =~ "in flight: nothing"
        {:ok, context}
      end

      then_ "the agent can deliberately claim unrelated component work", context do
        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            context.agent_frame
          )

        refute started.isError, response_text(started)
        second_task_id = extract_task_id!(started)
        assert second_task_id != context.task_id
        {:reply, active, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute active.isError, response_text(active)
        assert response_text(active) =~ "# Tasks (1)"
        assert response_text(active) =~ second_task_id
        refute response_text(active) =~ context.task_id

        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.agent_frame)
        refute questions.isError, response_text(questions)
        assert response_text(questions) =~ context.question_id

        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
