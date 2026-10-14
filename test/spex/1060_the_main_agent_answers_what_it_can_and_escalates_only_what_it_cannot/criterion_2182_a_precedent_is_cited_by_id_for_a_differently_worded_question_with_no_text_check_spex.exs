defmodule CodeMySpecSpex.Story1060.Criterion2182Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2182 — A precedent is cited by id for a differently worded
  question, with no text check.

  Retired criterion 1228 required a precedent's question text to match the
  new question's exactly, so a precedent stating a general rule could never
  fit a differently-worded question either (issue f43e1c5b). Per product's
  decision (John, 2026-10-13, question 839bf593): citing a precedent by id
  is the answerer's own judgement that it applies; there is no text check,
  and the citation is on the record either way.
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

  @earlier "Is CodeMySpec.Users.LocalScope dead code, given no spec, test or caller here?"
  @new_question "Is CodeMySpec.Billing.PlanScope dead code, given no spec, test or caller here?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A precedent stating a general rule fits a differently worded question",
       criterion: 2182 do
    scenario "the main agent cites a precedent whose own answer generalizes" do
      given_ "an answered question stating a general rule, and a new, differently worded question",
             context do
        reply = join_working_copy(context, "/tmp/spex-2182", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        earlier =
          Fixtures.ask_question(scope.user.id, title: "is this dead code", questions: [
            %{"question" => @earlier, "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
          ])

        :ok =
          Fixtures.answer_question(
            scope,
            earlier,
            "No — a component is a projection of a file that can live in another checkout, " <>
              "so its absence here is not evidence it does not exist elsewhere."
          )

        Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2182-main")
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2182")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "a different module, the same shape of question",
              questions: [
                %{
                  "question" => @new_question,
                  "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
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
         |> Map.put(:earlier, earlier)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent cites the earlier answer as precedent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "No — same reasoning as before: it may be a projection of a file " <>
                "that lives in another checkout.",
              basis: "precedent",
              precedent_id: context.earlier
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is accepted, with no requirement that the wording match", context do
        refute context.response.isError,
               """
               A precedent stating a general rule was refused against a
               differently-worded question, as if citing it required the exact
               same wording.

               reply:
               #{response_text(context.response)}
               """

        asker_frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, checked, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, asker_frame)

        assert response_text(checked) =~ "projection",
               """
               The asking agent was never told the precedent-grounded answer.

               reply:
               #{response_text(checked)}
               """

        {:ok, context}
      end

      then_ "and the user is not asked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               A question the main agent answered from precedent still reached
               the user.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
