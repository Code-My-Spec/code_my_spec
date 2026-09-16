defmodule CodeMySpecSpex.Story1060.Criterion3259Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3259 — Work to find an answer does not become a stall.

  Rule: trying and failing ends with the user, not with silence.

  The criterion that makes 3255 safe. "Go and find out" is right, and it has a
  failure mode the old behaviour did not: the main agent takes the question,
  looks, does not find it, and the question is now held by something that has
  stopped working on it. The asking agent waits on an answer nobody is
  producing, and the user never hears the question because it was never passed
  up.

  That is strictly worse than the main agent not having tried. Before this
  story the question went straight to the user — slower, and it arrived. Now it
  can be absorbed, and absorbed questions have no symptom: the inbox is quiet,
  the agent is quiet, and everything looks like a project where nobody needs
  anything.

  ## Searching and finding nothing is the case

  The scenario has the main agent do exactly what 3255 asks — look — and the
  project does not hold the answer. Both halves then have to hold: the user gets
  the question, and the agent is not left waiting.

  The second is asserted through the question's holder rather than through the
  agent, because "not left waiting" is not the absence of a message. It is the
  question being somewhere that will produce one.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.SearchAnswers
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @question "What is our retention period for deleted invoices?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A search that finds nothing still ends with the user" do
    scenario "the main agent looks and the project does not hold the answer" do
      given_ "an agent blocked on something nothing records", context do
        reply = join_working_copy(context, "/tmp/spex-3259", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3259")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "needs a policy nobody has written down",
              questions: [
                %{
                  "question" => @question,
                  "options" => [%{"label" => "30 days"}, %{"label" => "7 years"}]
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

      when_ "it works to answer and cannot", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Exactly what criterion 3255 asks for: go and look. The project does
        # not hold this one.
        {:reply, found, _frame} = SearchAnswers.execute(%{query: "retention"}, frame)

        refute found.isError, inspect(found)

        refute response_text(found) =~ ~r/7 years|30 days/,
               "the premise is a search that finds nothing:\n" <> response_text(found)

        :ok = Fixtures.give_up_on_question(context.scope, context.question_id)

        {:ok, context}
      end

      then_ "the question still reaches the user", context do
        {:ok, _live, html} = live(context.conn, "/app/notifications")

        assert html =~ @question,
               """
               The main agent tried, failed, and the question stopped there.

               This is strictly worse than not having tried: before this story
               the question went straight to the user — slower, and it arrived.
               Now it can be absorbed, and an absorbed question has no symptom.
               The inbox is quiet, the agent is quiet, and everything looks like
               a project where nobody needs anything.

               notifications:
               #{html}
               """

        {:ok, context}
      end

      then_ "and the asking agent is not waiting on work that will not conclude",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        assert response_text(listing) =~ ~r/waiting on the user/i,
               """
               The question is still held by the main agent, which has stopped
               working on it.

               "Not left waiting" is not the absence of a message — the agent is
               supposed to wait, that is what asking means. It is the question
               being somewhere that will produce an answer, and a main agent
               that has given up is not that place.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
