defmodule CodeMySpecSpex.Story1053.Criterion3269Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3269 — A chain of questions does not strand the agent that started
  it.

  Rule: an agent's own question tells it the truth about its own question.

  3264 is the same escalation seen by the main agent; this is it seen by the
  agent that asked. They are separate criteria because the two readers can
  disagree without anything being obviously broken — escalation moves the
  question's holder, and it is the *asker's* view that has no reason to be
  updated by that move.

  Both wrong answers strand it, in opposite ways. Told "answered", it resumes on
  an answer that does not exist. Told "abandoned" or shown nothing, it gives up
  on work that is merely waiting. The criterion asks for the third thing, which
  the system currently has no way to say: still open, and waiting on somebody
  else.

  That is why this is on story 1053 rather than 1060. Escalation is 1060's
  subject; what the chain looks like from the far end is a visibility
  requirement, and visibility is this story.

  Driven through `check_answer`, which is how an agent actually asks after its
  own question — the same call it would make on waking.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The agent that asked is told it is still waiting" do
    scenario "the main agent escalated and the user has not answered" do
      given_ "a coding agent's question escalated to the user and unanswered",
             context do
        reply = join_working_copy(context, "/tmp/spex-3269", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3269"
          )

        asking = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "needs something the main agent does not hold",
              questions: [
                %{
                  "question" => "Which region is this account allowed to use?",
                  "options" => [%{"label" => "eu-west-1"}, %{"label" => "us-east-1"}]
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
            %{question_id: question_id, reason: "operational, not technical"},
            main
          )

        refute escalated.isError, inspect(escalated)

        # Nobody answers. That is the state the criterion is about.
        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:coding, coding)
         |> Map.put(:question_id, question_id)}
      end

      when_ "the coding agent checks its own question", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        {:ok, Map.put(context, :answer, response_text(response))}
      end

      then_ "it is told the question is still open and waiting on the user",
            context do
        refute context.answer =~ ~r/\beu-west-1\b|\bus-east-1\b/,
               """
               The asking agent was handed an answer nobody gave.

               It will resume on it. Whatever it does next is built on a
               decision the user never made, and the user's own question is
               still sitting there unanswered — so nothing will ever contradict
               it.

               reply:
               #{context.answer}
               """

        refute context.answer =~ ~r/abandoned|cancelled|closed|no longer/i,
               """
               The asking agent was told its question is finished with.

               It gives up on work that is only waiting, and the user answers a
               question whose asker has already moved on.

               reply:
               #{context.answer}
               """

        assert context.answer =~ ~r/waiting on the user/i,
               """
               The asking agent is not told who its question is waiting on.

               "Still pending" is not enough here: the agent asked the main
               agent and is now waiting on a person, via a hop it never saw.
               Without being told, a chain that is progressing normally is
               indistinguishable from one that has stalled — and the agent's
               only options are to keep polling or to give up.

               reply:
               #{context.answer}
               """

        {:ok, context}
      end
    end
  end
end
