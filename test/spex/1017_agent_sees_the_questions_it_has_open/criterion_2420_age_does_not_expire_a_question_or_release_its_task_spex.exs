defmodule CodeMySpecSpex.Story1017.Criterion2420Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2420 — Age does not expire a durable question or release its task.

  Claim and ask through MCP, then establish that the unanswered question is
  eleven minutes old. Only timestamps are backdated; no answer or blocker
  state is manufactured. Public reads and an attempted resume observe whether
  age has incorrectly made the decision disappear or released the task.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An old unanswered question still blocks only its own task" do
    scenario "Eleven minutes without an answer does not expire the question or permit resume" do
      given_ :synced_context_component

      given_ "an authenticated coding agent has claimed an active task", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, graph, _} = GetNextRequirement.execute(%{}, frame)
        refute graph.isError, response_text(graph)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, active, _} = ListTasks.execute(%{status: "active"}, frame)
        refute active.isError, response_text(active)
        assert response_text(active) =~ task_id

        {:ok, Map.merge(context, %{agent_frame: frame, task_id: task_id})}
      end

      given_ "it has asked a structured question against its active task", context do
        {:reply, response, _} =
          AskUserQuestion.execute(
            %{
              title: "Choose the test contract",
              questions: [
                %{
                  question: "Should this input be rejected or normalized?",
                  options: [%{label: "Reject"}, %{label: "Normalize"}]
                }
              ]
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      given_ "the question has remained unanswered for eleven minutes", context do
        refute context.response.isError, response_text(context.response)

        [_, question_id] =
          Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(context.response))

        :ok = Fixtures.age_question(context.scope, question_id, 11 * 60)
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the agent checks the old question and its task", context do
        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.agent_frame)

        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.agent_frame)
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:ok, Map.merge(context, %{answer: answer, questions: questions, tasks: tasks})}
      end

      then_ "the question is still pending and visible with its original task link", context do
        refute context.answer.isError, response_text(context.answer)
        assert response_text(context.answer) =~ "Still waiting"
        refute response_text(context.answer) =~ ~r/expired/i
        refute context.questions.isError, response_text(context.questions)
        assert response_text(context.questions) =~ context.question_id
        assert response_text(context.questions) =~ context.task_id
        assert response_text(context.questions) =~ "Should this input be rejected or normalized?"
        refute response_text(context.questions) =~ ~r/expired/i

        refute context.tasks.isError, response_text(context.tasks)
        assert response_text(context.tasks) =~ "# Tasks (1)"
        assert response_text(context.tasks) =~ context.task_id
        assert response_text(context.tasks) =~ "[blocked]"
        refute response_text(context.tasks) =~ "[active]"
        {:ok, context}
      end

      then_ "age alone cannot authorize resuming the unanswered task", context do
        {:reply, refused, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            context.agent_frame
          )

        assert refused.isError, response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"
        {:ok, context}
      end
    end
  end
end
