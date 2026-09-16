defmodule CodeMySpecSpex.Story1060.Criterion3255Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3255 — The main agent goes and finds out.

  Rule: "I do not know" is the start of the work, not the end of it.

  The criterion that separates this story from a lookup table. 3251 is a
  question the main agent can answer from what it is already holding; this one
  it cannot — and the right move is to query the project, not to escalate.

  Without it the honest implementation of every other criterion here is a main
  agent that answers the easy questions and passes on everything else, which is
  a router. The user still gets interrupted, just less often, and the things
  that reach them are exactly the things that took one more step to answer.

  ## The distinction from 3254

  3254 refuses an answer the project cannot support. This requires an answer the
  project *can* support but the main agent had not yet looked up. They are
  opposite failures at the same fork — one is answering without looking, the
  other is escalating without looking — and a main agent that got 3254 right by
  never answering anything would fail here.

  ## Driven through the digest, not a pre-loaded context

  The scenario hands the main agent nothing. If it answers, it went and asked.

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
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadyStoriesWithoutEpic
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

  spex "Not knowing is a reason to look, not to escalate" do
    scenario "a blocked product agent needs something the main agent must look up" do
      given_ "a blocked agent and a project that can answer if asked", context do
        reply = join_working_copy(context, "/tmp/spex-3255", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{name: "Billing", slug: "billing"})
        in_epic = Fixtures.authored_story(scope, "Invoices export")
        :ok = Fixtures.put_story_in_epic(scope, in_epic, epic)
        :ok = Fixtures.mark_story_ready(scope, in_epic)

        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3255")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "blocked on epic membership",
              questions: [
                %{
                  "question" => "Which ready story has no epic?",
                  "options" => [%{"label" => "A"}, %{"label" => "B"}]
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

      when_ "it handles the question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Nothing was handed to it. If it can answer, it went and asked.
        {:reply, found, _frame} = ReadyStoriesWithoutEpic.execute(%{}, frame)

        refute found.isError, inspect(found)

        {:reply, answered, _frame} =
          AnswerNotification.execute(
            %{
              id: context.question_id,
              answer: response_text(found),
              basis: "record"
            },
            frame
          )

        refute answered.isError, inspect(answered)

        {:ok, context}
      end

      then_ "it answers the agent", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.agent.id}
        }

        {:reply, response, _frame} =
          CheckAnswer.execute(%{question_id: context.question_id}, frame)

        assert response_text(response) =~ "Dunning emails go out",
               """
               The main agent could have found the answer and did not.

               Without this criterion the honest implementation of the rest of
               this story is a main agent that answers what it already holds and
               passes on everything else — a router. The user still gets
               interrupted, just less often, and the things that reach them are
               exactly the ones that took one more step.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "without involving the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user was asked something the project could answer.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
