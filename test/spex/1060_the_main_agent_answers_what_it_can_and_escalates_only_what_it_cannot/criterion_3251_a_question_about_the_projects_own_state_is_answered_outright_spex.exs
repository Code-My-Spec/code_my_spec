defmodule CodeMySpecSpex.Story1060.Criterion3251Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3251 — A question about the project's own state is answered
  outright.

  The first spex on this story, so it fixes the shape the rest inherit: an
  answer carries a **basis** — what it rests on — and `answer_question` refuses
  one without.

  ## Why a basis and not just an answer

  Every other criterion here is a judgement about whether the main agent *may*
  answer, and none of them is checkable from the answer's text. "Dunning emails
  go out" is a good answer to "which ready story has no epic" and a guess in
  reply to "should we build dunning emails" — the words are identical and the
  difference is entirely in what the main agent had to go on.

  So the basis is the thing the system can check. `:record` says the project
  records this; criterion 3257's `:precedent` says the user already decided it;
  and an answer with neither is refused, which is 3254.

  This criterion is the easy case and the reason the feature exists: the user
  should never be interrupted by something the system already knows.

  ## "The user was not asked" is the holder, not the inbox

  The inbox keeps answered questions as history and never renders the answering
  form — that lives on the question's own page — so neither the text being
  present nor a form being absent says anything here. What the criterion is
  about is that nothing is waiting on the person, and `list_open_questions` is
  where that is said.
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

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What the project records, the main agent answers" do
    scenario "a product agent asks which ready story is not in an epic" do
      given_ "a project that records the answer, and an agent asking for it",
             context do
        reply = join_working_copy(context, "/tmp/spex-3251", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{name: "Billing", slug: "billing"})
        in_epic = Fixtures.authored_story(scope, "Invoices export")
        :ok = Fixtures.put_story_in_epic(scope, in_epic, epic)
        :ok = Fixtures.mark_story_ready(scope, in_epic)

        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3251")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "cannot see epic membership",
              questions: [
                %{
                  "question" => "Which ready story is not in an epic?",
                  "options" => [
                    %{"label" => "Invoices export"},
                    %{"label" => "Dunning emails go out"}
                  ]
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
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles the question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "Dunning emails go out",
              basis: "record"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "it answers with that story", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ "Dunning emails go out",
               """
               The agent did not get its answer.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "and the user was not asked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListOpenQuestions.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user was interrupted by a question the system already knew
               the answer to.

               Their attention is the scarce resource this whole story is
               about. A question they have to go and look up in their own
               project's records is the clearest possible case of an
               interruption that should never have reached them.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
