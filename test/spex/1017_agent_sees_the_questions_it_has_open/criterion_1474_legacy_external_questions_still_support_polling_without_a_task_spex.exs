defmodule CodeMySpecSpex.Story1017.Criterion3576Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 3576 — Legacy external questions support polling without a task.

  Register an external session through its hook, ask through MCP, answer on
  the question page, and collect the reply through MCP. No question, task,
  or answer is seeded; both task and durable-agent listings remain empty.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @question "Should the external session keep the current behavior?"
  @answer "Keep it"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An external session asks and polls without acquiring a task or durable agent",
    criterion: 1474 do
    scenario "The existing session question round trip survives work-management changes" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a registered external session has no task or durable agent", context do
        session_id = "spex-3576-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, tasks, _} = ListTasks.execute(%{session_id: session_id}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:reply, agents, _} = ListAgents.execute(%{}, frame)
        refute agents.isError, response_text(agents)
        assert response_text(agents) == "No agents are running on this project."
        {:ok, Map.merge(context, %{session_id: session_id, frame: frame})}
      end

      when_ "the session asks without a task link", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{question: @question, options: [%{label: @answer}, %{label: "Change it"}]}
              ]
            },
            context.frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the session can list and poll its unanswered question", context do
        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.frame)
        refute questions.isError, response_text(questions)
        assert response_text(questions) =~ context.question_id
        assert response_text(questions) =~ @question

        {:reply, pending, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute pending.isError, response_text(pending)
        assert response_text(pending) =~ "Still waiting on the user"
        {:ok, context}
      end

      when_ "the user answers on the question page", context do
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:ok, context}
      end

      then_ "polling returns the saved answer without creating a task or staffing an agent",
            context do
        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "The user replied"
        assert response_text(answer) =~ @answer

        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.frame)
        refute questions.isError, response_text(questions)
        refute response_text(questions) =~ context.question_id

        {:reply, tasks, _} =
          ListTasks.execute(%{session_id: context.session_id}, context.frame)

        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:reply, agents, _} = ListAgents.execute(%{}, context.frame)
        refute agents.isError, response_text(agents)
        assert response_text(agents) == "No agents are running on this project."
        {:ok, context}
      end
    end
  end
end
