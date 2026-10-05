defmodule CodeMySpecSpex.Story1060.Criterion1985Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1985 — A QA agent stuck on its environment is unstuck by the main
  agent.

  Rule: the main agent does work to answer a question before putting it to
  the user. `EnsureAppRunning` and `RestartApp` are scoped to the caller's
  own copy by design (story 1108) — "always the caller's own copy, never a
  parameter" — which is exactly why a QA agent that cannot get its own app
  running has nowhere further to go on its own. The main agent, which holds
  the whole project rather than one checkout, is the one with reach past
  that wall.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent restarts a QA agent's app for it, past the copy it cannot reach",
       criterion: 1985 do
    scenario "a QA agent's app is serving an old commit and it cannot restart it" do
      given_ "a QA agent whose own copy's app is stuck, past its own reach", context do
        reply = join_working_copy(context, "/tmp/spex-1985", "the QA checkout")
        qa_scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        qa_agent =
          Fixtures.running_agent(qa_scope, role: "qa", working_copy: "/tmp/spex-1985")

        asking = %Frame{assigns: %{current_scope: qa_scope, agent_id: qa_agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "my app will not restart",
              questions: [
                %{
                  "question" => "My copy's app is serving an old commit and I cannot restart it myself. Can you?",
                  "options" => [%{"label" => "yes"}, %{"label" => "no"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, qa_scope)
         |> Map.put(:qa_agent, qa_agent)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles the question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, read, _frame} =
          ReadAgentConversation.execute(%{agent_id: context.qa_agent.id}, frame)

        refute read.isError, inspect(read)

        {:reply, answered, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "Restarted /tmp/spex-1985's app — it is serving your copy's current commit.",
              basis: "record"
            },
            frame
          )

        {:ok, Map.put(context, :answered, answered)}
      end

      then_ "it restarts the copy's app itself and answers that it is serving the copy's commit",
            context do
        refute context.answered.isError, inspect(context.answered)

        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.qa_agent.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ ~r/serving/i,
               """
               The QA agent was never told its app is serving its copy's commit
               again.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "and the user is not asked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user was interrupted by an environment problem the main agent
               could fix itself.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
