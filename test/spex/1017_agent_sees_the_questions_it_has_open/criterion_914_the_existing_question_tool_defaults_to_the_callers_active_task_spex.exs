defmodule CodeMySpecSpex.Story1017.Criterion2421Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2421 — The existing question tool defaults to the caller's active task.

  Claim through start_task, ask through ask_question, and observe both
  effects through the agent's task and question listings. No task blocker or
  question is seeded. Transaction rollback is covered by criterion 3575.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
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

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        task_id = extract_task_id!(started)

        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ task_id

        {:ok, Map.merge(context, %{agent_frame: frame, task_id: task_id})}
      end

      when_ "it asks a structured question without task_id", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{
              title: "Choose the test contract",
              questions: [
                %{
                  question: "Should this input be rejected or normalized?",
                  options: [%{label: "Reject"}, %{label: "Normalize"}]
                }
              ]
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool returns an unanswered question and the task is already blocked", context do
        assert match?({:ok, _}, context.response), response_text(context.response)

        [_, question_id] =
          Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(context.response))

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"

        questions =
          ToolLibrary.run(
            "list_user_questions",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, questions), response_text(questions)
        assert response_text(questions) =~ question_id
        assert response_text(questions) =~ context.task_id
        assert response_text(questions) =~ "Should this input be rejected or normalized?"
        {:ok, context}
      end
    end
  end
end
