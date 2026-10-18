defmodule CodeMySpecSpex.Story1017.Criterion2421Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2421 — The existing question tool defaults to the caller's active task.

  Claim through start_task, ask through ask_user_question, and observe both
  effects through the agent's task and question listings. No task blocker or
  question is seeded. Transaction rollback is covered by criterion 3575.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent asks against its active task without supplying its id", criterion: 914 do
    scenario "The committed question and blocked task have the same durable link" do
      given_ :synced_context_component

      given_ "an authenticated coding agent has claimed an active task", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        graph =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, graph), response_text(graph)

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

      when_ "it asks a structured question without task_id", context do
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

      then_ "the tool returns an unanswered question and the task is already blocked", context do
        refute context.response.isError, response_text(context.response)

        [_, question_id] =
          Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(context.response))

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"

        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.agent_frame)
        refute questions.isError, response_text(questions)
        assert response_text(questions) =~ question_id
        assert response_text(questions) =~ context.task_id
        assert response_text(questions) =~ "Should this input be rejected or normalized?"
        {:ok, context}
      end
    end
  end
end
