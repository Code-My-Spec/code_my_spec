defmodule CodeMySpecSpex.Story1058.Criterion3314Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3314 — A blocked agent is unblocked rather than merely observed.

  Rule: reach is for using, not for reporting.

  Story 1053 gave the main agent the list of open questions and a way to pass
  one up. This says the list is not the product: a main agent that can see
  everything and answer nothing has replaced a person's inbox with its own, and
  the agent waits exactly as long as before with one more hop in the way.

  ## The point of the wider reach

  The question in the scenario is answerable *only* because the main agent reads
  past the asking role — that is criterion 3313's capability, used. Escalating
  it (story 1053's `escalate_question`) would be the wrong move and would look
  correct: the user would get a question about their own project's records, and
  answering it would mean going and looking up something the system already
  knows.

  ## What "carries on" means here

  The answer reaches the agent, which is story 1053's `check_answer` path — the
  same delivery a person's answer takes, because the agent has no way to tell
  the two apart and should not need one. The criterion's "rather than waiting
  for a person" is asserted as the question no longer being held by the user.

  ## The answer carries a basis

  Story 1060 made `answer_question` refuse an answer with nothing behind it —
  the main agent under instruction to spare the user is rewarded for answering,
  so the check is the system's rather than a guideline. These scenarios answer
  from what the project records, so they say so and the record is there to be
  checked.
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

  spex "The main agent answers instead of forwarding" do
    scenario "an agent stopped for want of something the project records" do
      given_ "a product agent blocked on which ready story has no epic", context do
        reply = join_working_copy(context, "/tmp/spex-3314", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{name: "Billing", slug: "billing"})
        in_epic = Fixtures.authored_story(scope, "Invoices export")
        :ok = Fixtures.put_story_in_epic(scope, in_epic, epic)
        :ok = Fixtures.mark_story_ready(scope, in_epic)

        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3314")

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

      when_ "the main agent handles that question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "Dunning emails go out — it is ready and belongs to no epic",
              basis: "record"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "the agent has its answer", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ "Dunning emails go out",
               """
               The main agent could see the answer and the agent still does not
               have it.

               Story 1053 gave the main agent the list and a way to pass a
               question up. If that is all it can do, it has replaced a person's
               inbox with its own: the agent waits exactly as long as before,
               with one more hop in the way.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "and nobody was interrupted to supply it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, listing, _frame} =
          ListOpenQuestions.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The question was passed to the user rather than answered.

               It is a question about this project's own records, and escalating
               it looks correct right up to the moment the person reads it: they
               would have to go and look up something the system already knows,
               which is the errand the main agent exists to remove.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
