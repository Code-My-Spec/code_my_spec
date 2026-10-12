defmodule CodeMySpecSpex.Story1053.Criterion2027Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 2027 — The main agent answers on notification, without waiting
  for a check-in. Title only; no scenario was recorded.

  Rule: a persisted question immediately reconsiders eligible main-agent work
  through normal turn admission, without a generic push message.

  2026 is about the reconsideration being triggered right away; this is about
  what the main agent then does with it — settling a question it can answer
  outright, the same path 1983 (story 1060) exercises, without this scenario
  ever calling `CheckIn` first. If a check-in were a prerequisite, this would
  have nothing to answer yet.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
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

  spex "The main agent settles a fresh question it can answer, with no check-in in between",
    criterion: 2027 do
    scenario "a coding agent asks a question the main agent can answer outright" do
      given_ "a coding agent's fresh question the main agent can settle from its own records",
             context do
        reply = join_working_copy(context, "/tmp/spex-2027", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2027")
        # An on-duty main holds the question; with none, it goes to the user (1052, 2124).
        _main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2027-main")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  "question" => "Which working copy is this agent running on?",
                  "options" => [%{"label" => "/tmp/spex-2027"}, %{"label" => "somewhere else"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, response_text(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:coding, coding)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent answers it directly, never having called CheckIn", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, answered, _} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "/tmp/spex-2027",
              basis: "record"
            },
            frame
          )

        {:ok, Map.put(context, :answered, answered)}
      end

      then_ "the answer succeeds", context do
        refute context.answered.isError,
               """
               The main agent could not answer the question without a prior
               check-in.

               reply:
               #{response_text(context.answered)}
               """

        {:ok, context}
      end

      then_ "the asking agent sees the answer", context do
        asking = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coding.id}}
        {:reply, response, _} = CheckAnswer.execute(%{question_id: context.question_id}, asking)

        assert response_text(response) =~ "/tmp/spex-2027",
               """
               The asking agent was never told the answer.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "the question no longer waits on the main agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, inbox, _} = ListNotifications.execute(%{}, frame)

        refute response_text(inbox) =~ context.question_id,
               """
               The answered question is still listed as waiting.

               listing:
               #{response_text(inbox)}
               """

        {:ok, context}
      end
    end
  end
end
