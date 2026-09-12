defmodule CodeMySpecSpex.Story1060.Criterion3257Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3257 — A settled question is not put to the user twice.

  Rule: a decision the user made is an answer the main agent holds.

  The second `basis`. 3251's is the project's records; this is the user's own
  earlier decision, and it belongs in the same mechanism because it is the same
  kind of thing — something already true that the main agent can look up rather
  than ask about.

  Asking twice is the most corrosive interruption available. It is not merely
  redundant: it tells the user their answer was not recorded, or was not read,
  and the reasonable inference is that answering carefully is not worth the
  effort. Two or three of those and the inbox becomes something to clear rather
  than something to read — which costs every future question, including the ones
  that matter.

  ## Saying where the answer came from

  The criterion's middle clause and not decoration. An answer presented as the
  main agent's own is one the agent will weigh as a judgement; the same words
  attributed to the user's earlier decision are a fact, and the difference
  changes what the agent does when something else contradicts it.

  It is also the user's only way to notice a precedent being applied where it
  should not be — 3258's failure, seen from the outside.

  ## "Not asked again" is the holder, not the inbox

  The inbox keeps every question as history, so the same words appear twice
  there whatever happened — once for the decision they made and once for the
  question that was answered from it. What the criterion is about is whether
  anything is waiting on them now, which is what `list_open_questions` says.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @question "Should deleting a customer delete their invoices?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The user is not asked what they have already decided" do
    scenario "the same question comes round again" do
      given_ "the user has already answered it, and an agent asks it again",
             context do
        reply = join_working_copy(context, "/tmp/spex-3257", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        settled =
          Fixtures.ask_question(scope.user.id,
            title: "decided last week",
            questions: [
              %{
                "question" => @question,
                "options" => [%{"label" => "Keep"}, %{"label" => "Delete"}]
              }
            ]
          )

        :ok = Fixtures.answer_question(scope, settled, "Keep")

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3257")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "the same decision again",
              questions: [
                %{
                  "question" => @question,
                  "options" => [%{"label" => "Keep"}, %{"label" => "Delete"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:agent, agent)
         |> Map.put(:settled, settled)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "Keep",
              basis: "precedent",
              precedent_id: context.settled
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "it answers from that earlier answer, and says so", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ "Keep",
               "the agent did not get the answer:\n#{response_text(response)}"

        assert response_text(response) =~
                 ~r/already (decided|answered)|earlier (decision|answer)/i,
               """
               The answer arrives as the main agent's own opinion.

               An answer presented that way is one the agent weighs as a
               judgement; the same words attributed to a decision the user
               already made are a fact, and the difference changes what the
               agent does when something else contradicts it.

               It is also the user's only way to notice a precedent being
               applied where it should not be.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "and the user is not asked again", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListOpenQuestions.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user is looking at the same question twice.

               This is the most corrosive interruption available: it tells them
               their answer was not recorded, or was not read, and the
               reasonable inference is that answering carefully is not worth the
               effort. Two or three of those and the inbox becomes something to
               clear rather than something to read — which costs every future
               question, including the ones that matter.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
