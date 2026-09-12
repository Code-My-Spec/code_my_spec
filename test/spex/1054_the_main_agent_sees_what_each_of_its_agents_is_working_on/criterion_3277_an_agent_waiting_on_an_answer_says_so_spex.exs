defmodule CodeMySpecSpex.Story1054.Criterion3277Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3277 — An agent waiting on an answer says so.

  Rule: a silence with a cause names the cause.

  The first of three criteria — with 3278 and 3279 — that each take one ordinary
  reason an agent is quiet and require the view to say which. They are separate
  because the reasons are separate and a view can carry one and miss the others;
  together they are what makes 3274's "the silence is visible" worth anything,
  because a silence with no cause attached is a fact the main agent still has to
  go and explain.

  This one is the case the main agent can act on directly. An agent waiting on a
  question is not stuck and does not need restarting — it needs somebody to
  answer, and story 1053 gave the main agent both the list and the means. So the
  cost of getting it wrong is not just a wrong reading: it is a restart that
  throws away the work, and an unanswered question that survives it and blocks
  the replacement in exactly the same way.

  The question's own text is asserted rather than a flag. "Waiting on an answer"
  tells the main agent to go and find out which; the thing it needs is already
  in hand.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A quiet agent that is waiting shows what it is waiting for" do
    scenario "an agent asked a question and nobody has answered" do
      given_ "an agent that asked a question and then went quiet", context do
        reply = join_working_copy(context, "/tmp/spex-3277", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3277"
          )

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "needs a decision before it can carry on",
              questions: [
                %{
                  "question" => "Should deleting an account keep its invoices?",
                  "options" => [%{"label" => "Keep"}, %{"label" => "Delete"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        # Quiet ever since, which is correct behaviour: an agent that asked is
        # told to stop rather than poll.
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 20 * 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the open question is shown against it", context do
        assert context.view =~ "Should deleting an account keep its invoices?",
               """
               The agent is shown as quiet with nothing to say why.

               This is the one case the main agent can settle on the spot: an
               agent waiting on a question does not need restarting, it needs
               somebody to answer, and story 1053 gave the main agent both the
               list and the means.

               Read as an unexplained silence instead, the remedy it reaches for
               is a restart — which throws away the work and leaves the question
               unanswered, so the replacement blocks on it in exactly the same
               way.

               The question's text rather than a "waiting" flag, because a flag
               sends the main agent to go and find out which question; the thing
               it needs is already in hand.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
