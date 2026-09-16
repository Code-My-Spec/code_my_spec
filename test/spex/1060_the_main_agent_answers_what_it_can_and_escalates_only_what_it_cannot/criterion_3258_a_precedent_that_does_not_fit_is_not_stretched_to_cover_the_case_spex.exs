defmodule CodeMySpecSpex.Story1060.Criterion3258Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3258 — A precedent that does not fit is not stretched to cover the
  case.

  Rule: a precedent is the same question, not a similar one.

  3257's dangerous edge, and the reason precedent needs a check rather than a
  search. A search returns similar text by construction, and "similar" is what
  makes a precedent tempting — the more useful the search, the more often it
  hands back something that reads like an answer to a different question.

  The failure is invisible in both directions. The agent gets a confident
  answer attributed to the user, which is the strongest possible provenance and
  the hardest to question. The user never sees the question, so they never learn
  their earlier decision was applied to a case they might have decided the other
  way. Nothing anywhere records that a judgement was made.

  ## What makes it not fit, in the scenario

  The earlier decision was about a *customer's* invoices. The new question is
  about an *account* being closed — same verb, same records, and a materially
  different subject: a customer leaving is not a business shutting down, and the
  retention answer plausibly differs.

  The main agent naming it as precedent is exactly the mistake, so that is what
  the scenario does — and the system must refuse it rather than trust the claim.

  ## "Reached the user" is the holder, not the inbox

  The notifications inbox lists every question pending for the person whatever
  its holder is, so finding the text there says only that somebody asked —
  which was true before the main agent did anything. What the criterion is
  about is who holds it now, and story 1053 already built the vocabulary:
  `list_open_questions` says `waiting on the user` when it has been passed up.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @earlier "Should deleting a customer delete their invoices?"
  @new_question "Should closing an account delete its invoices?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A similar decision is not the same decision" do
    scenario "the new question differs in a way that could change the answer" do
      given_ "an answered question about customers and a new one about accounts",
             context do
        reply = join_working_copy(context, "/tmp/spex-3258", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        earlier =
          Fixtures.ask_question(scope.user.id,
            title: "decided last week",
            questions: [
              %{
                "question" => @earlier,
                "options" => [%{"label" => "Keep"}, %{"label" => "Delete"}]
              }
            ]
          )

        :ok = Fixtures.answer_question(scope, earlier, "Keep")

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3258")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "a different subject, the same verb",
              questions: [
                %{
                  "question" => @new_question,
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
         |> Map.put(:earlier, earlier)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent offers the earlier answer as precedent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerNotification.execute(
            %{
              id: context.question_id,
              answer: "Keep",
              basis: "precedent",
              precedent_id: context.earlier
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not apply the earlier answer", context do
        assert context.response.isError,
               """
               A decision about deleting a customer was applied to closing an
               account.

               Same verb, same records, materially different subject — a
               customer leaving is not a business shutting down, and the
               retention answer plausibly differs.

               The failure is invisible in both directions. The agent gets a
               confident answer attributed to the user, which is the strongest
               provenance there is and the hardest to question; the user never
               sees the question, so they never learn their decision was applied
               to a case they might have decided the other way.

               A search returns similar text by construction, which is what
               makes precedent tempting — the more useful the search, the more
               often it hands back an answer to a different question. So the
               claim has to be checked rather than trusted.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the question goes to the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        assert response_text(listing) =~ ~r/waiting on the user/i,
               """
               The precedent was refused and the question reached nobody.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
