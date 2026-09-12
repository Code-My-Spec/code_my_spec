defmodule CodeMySpecSpex.Story1053.Criterion3268Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3268 — A technical question needs an operational answer first.

  Rule: the main agent closes the loop it opened.

  The whole chain, end to end, and the only criterion here that asserts the
  agent gets its answer back. 3264 and 3269 describe the middle of this chain —
  what each end sees while it is open. This one says the chain terminates.

  It is worth its own criterion because the failure is a slow leak rather than a
  break. Escalation works, the user answers, and nothing carries that answer
  back to the agent that needed it: the user believes they have unblocked
  somebody, the main agent's list is clean, and the coding agent waits
  indefinitely on a question that has been answered. Every surface looks
  healthy. Only the work stops.

  The distinction from 3269 is which side is tested. There the user has *not*
  answered and the asker must be told it is still waiting; here the user *has*,
  and the answer has to arrive. A system that told the truth while waiting and
  then dropped the answer would satisfy 3269 and fail this.

  The user answers through `answer_question_request/2`, the call the inbox form
  makes, so "answered" means what the product means.
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

  spex "The answer reaches the agent that needed it" do
    scenario "the user answers what the main agent could not" do
      given_ "a coding agent's question escalated to the user", context do
        reply = join_working_copy(context, "/tmp/spex-3268", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3268"
          )

        asking = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "technical, blocked on something operational",
              questions: [
                %{
                  "question" => "Which registry do we push images to?",
                  "options" => [%{"label" => "ghcr"}, %{"label" => "ecr"}]
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
            %{question_id: question_id, reason: "the main agent does not know our registry"},
            main
          )

        refute escalated.isError, inspect(escalated)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:coding, coding)
         |> Map.put(:question_id, question_id)}
      end

      when_ "the user answers it", context do
        :ok = CodeMySpecSpex.Fixtures.answer_question(context.scope, context.question_id, "ghcr")

        {:ok, context}
      end

      then_ "the coding agent has its answer", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ "ghcr",
               """
               The user's answer never reached the agent that needed it.

               This is the failure mode that leaves every surface looking
               healthy: the user believes they unblocked somebody, the main
               agent's list is clean, and the coding agent waits forever on a
               question that has been answered. Nothing reports it, because from
               each vantage the chain completed.

               A system that keeps the asker correctly informed while it waits —
               criterion 3269 — and then drops the answer satisfies that
               criterion and fails this one, which is why they are separate.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end
    end
  end
end
