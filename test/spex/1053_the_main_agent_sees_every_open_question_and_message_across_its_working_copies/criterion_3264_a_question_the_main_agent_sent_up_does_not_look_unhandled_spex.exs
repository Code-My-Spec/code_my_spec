defmodule CodeMySpecSpex.Story1053.Criterion3264Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3264 — A question the main agent sent up does not look unhandled.

  Rule: a question has one holder at a time, and the list says who.

  The list has two readers with opposite needs, and this is where they meet.
  3262 removes what is finished; this removes what is finished *for the main
  agent* while it is still very much open for the person. Delete it and the main
  agent sees its own escalations forever, and cannot tell the ones it has dealt
  with from the ones it has not. Mark it answered and the person's question
  vanishes from under them, which is 3262's failure in the other direction.

  So neither "open" nor "closed" is the right answer, and that is the finding
  this criterion encodes: a question needs a holder, not a boolean.

  `EscalateQuestion` is named here and belongs to story 1060, which is about
  deciding *what* to escalate. This criterion only needs the act to exist and
  the listing to reflect it — which is the normal shape when two stories share a
  surface, and better than inventing a second way to escalate for the sake of
  keeping the spex self-contained.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An escalated question waits on the user, not the main agent" do
    scenario "the main agent could not answer and sent it up" do
      given_ "a coding agent's question that the main agent has escalated",
             context do
        reply = join_working_copy(context, "/tmp/spex-3264", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3264"
          )

        asking = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "beyond what the main agent knows",
              questions: [
                %{
                  "question" => "Which of our AWS accounts should this deploy to?",
                  "options" => [%{"label" => "production"}, %{"label" => "staging"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)
        question_id = CodeMySpecSpex.Fixtures.question_id_from(response_text(asked))

        main = %Frame{assigns: %{current_scope: scope}}

        {:reply, escalated, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: question_id,
              reason: "the main agent does not know which account is ours"
            },
            main
          )

        refute escalated.isError,
               "the escalation had to happen for this to mean anything:\n" <>
                 inspect(escalated)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:question_id, question_id)}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListOpenQuestions.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :listing, response_text(response))}
      end

      then_ "it is shown as waiting on the user, not on the main agent", context do
        assert context.listing =~ context.question_id,
               """
               The escalated question has disappeared from the main agent's
               list entirely.

               Then the main agent cannot tell an escalation it has dealt with
               from one it has not, and the agent that asked has nobody tracking
               its question at all. Gone is not the same as handled — that is
               3262's rule applied where it does not belong.

               listing:
               #{context.listing}
               """

        assert context.listing =~ ~r/waiting on the user/i,
               """
               The escalated question is not shown as waiting on the user.

               A question has one holder at a time and the list has to say who.
               Left looking like it still needs the main agent's attention, it
               competes with the questions that actually do — and the main agent
               either answers it again or treats its own escalations as noise,
               which is how a list stops being read.

               listing:
               #{context.listing}
               """

        refute context.listing =~ ~r/needs your attention/i,
               "an escalated question is still being offered to the main agent as its own"

        {:ok, context}
      end
    end
  end
end
