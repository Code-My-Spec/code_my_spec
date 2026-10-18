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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An old unanswered question still blocks only its own task", criterion: 913 do
    scenario "Eleven minutes without an answer does not expire the question or permit resume" do
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

      given_ "it has asked a structured question against its active task", context do
        response =
          ToolLibrary.run(
            "ask_user_question",
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

      given_ "the question has remained unanswered for eleven minutes", context do
        assert match?({:ok, _}, context.response), response_text(context.response)

        [_, question_id] =
          Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(context.response))

        :ok = Fixtures.age_question(context.scope, question_id, 11 * 60)
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the agent checks the old question and its task", context do
        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

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

        {:ok, Map.merge(context, %{answer: answer, questions: questions, tasks: tasks})}
      end

      then_ "the question is still pending and visible with its original task link", context do
        assert match?({:ok, _}, context.answer), response_text(context.answer)
        assert response_text(context.answer) =~ "Still waiting"
        refute response_text(context.answer) =~ ~r/expired/i
        assert match?({:ok, _}, context.questions), response_text(context.questions)
        assert response_text(context.questions) =~ context.question_id
        assert response_text(context.questions) =~ context.task_id
        assert response_text(context.questions) =~ "Should this input be rejected or normalized?"
        refute response_text(context.questions) =~ ~r/expired/i

        assert match?({:ok, _}, context.tasks), response_text(context.tasks)
        assert response_text(context.tasks) =~ "# Tasks (1)"
        assert response_text(context.tasks) =~ context.task_id
        assert response_text(context.tasks) =~ "[blocked]"
        refute response_text(context.tasks) =~ "[active]"
        {:ok, context}
      end

      then_ "age alone cannot authorize resuming the unanswered task", context do
        refused =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:error, _}, refused), response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i

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
        {:ok, context}
      end
    end
  end
end
