defmodule CodeMySpecSpex.Story1017.Criterion3575Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 3575 — A failed question write does not block the task.

  The database refuses the insert for this test user. The tool still receives
  a valid question and an owned active task. Read task state and the real user
  inbox afterward; no test transaction wraps the action to undo its mistakes.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question that cannot be saved neither blocks work nor reaches the inbox" do
    scenario "The failed ask leaves its active task and continuous intent unchanged" do
      given_ "the caller owns an active task and its inbox is observable", context do
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {agent, task} = Fixtures.agent_task_fixture(context.scope, agent)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ task.id
        assert response_text(tasks) =~ "[active]"
        {:reply, inbox, _} = ListNotifications.execute(%{}, frame)
        refute inbox.isError, response_text(inbox)

        {:ok,
         Map.merge(context, %{
           frame: frame,
           task_id: task.id,
           tasks_before: response_text(tasks),
           inbox_before: response_text(inbox),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      given_ "the database will refuse a question insert for this user", context do
        :ok = Fixtures.refuse_question_inserts(context.scope)
        {:ok, context}
      end

      when_ "the agent asks a valid question linked to its active task", context do
        {:reply, response, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              title: "A question whose write fails",
              questions: [
                %{
                  question: "Which refund policy should I implement?",
                  options: [%{label: "14 days"}, %{label: "30 days"}]
                }
              ]
            },
            context.frame
          )

        # The existing tool logs its rescued stale-write exception. Accept
        # only that induced error; unrelated errors still fail this scenario.
        Enum.each(SexySpex.ErrorCapture.get_errors(), fn error ->
          assert error.message =~ "[AskUserQuestion] crashed: attempted to insert a stale struct"
          assert error.message =~ "CodeMySpec.Notifications.QuestionRequest"
        end)

        SexySpex.ErrorCapture.clear()
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool reports failure and no question or blocker has been committed", context do
        assert context.response.isError, response_text(context.response)
        refute response_text(context.response) =~ ~r/Asked \d+ question/

        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        refute response_text(tasks) =~ "[blocked]"

        {:reply, inbox, _} = ListNotifications.execute(%{}, context.frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) == context.inbox_before
        refute response_text(inbox) =~ "Which refund policy should I implement?"

        {:ok, view, _} = live(context.conn, context.conversation_path)
        refute has_element?(view, "main [data-test='question-form']")
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
