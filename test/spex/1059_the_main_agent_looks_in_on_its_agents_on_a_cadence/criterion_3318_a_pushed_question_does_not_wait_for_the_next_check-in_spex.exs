defmodule CodeMySpecSpex.Story1059.Criterion3318Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3318 — A pushed question does not wait for the next check-in.

  Rule: the cadence is a floor, not a schedule.

  Story 1053's criterion 3265 already says a question is delivered rather than
  discovered, and its moduledoc names this story as the thing that makes that
  claim easy to mistake for satisfied: a question raised now *will* be seen, at
  the next tick.

  This is the same claim from the cadence's side, and it exists because adding
  a timer is exactly what tempts an implementation to lean on it. Delivery
  becomes "the next check-in will pick it up", which is true, cheap, and turns
  every blocked agent's wait into a whole interval — twenty minutes by default,
  paid by an agent that cannot do anything else in the meantime.

  ## The cadence is deliberately not ticked

  Nothing in this scenario wakes the main agent. If the question is in its
  thread, it was pushed there — and a cadence that had to run first would leave
  nothing to find.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question arrives between check-ins" do
    scenario "an agent asks while the cadence is not due" do
      given_ "a main agent and a coding agent, between check-ins", context do
        reply = join_working_copy(context, "/tmp/spex-3318", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3318")
        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3318")

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:coding, coding)}
      end

      when_ "an agent asks a question", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding.id}
        }

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              title: "asked between check-ins",
              questions: [
                %{
                  "question" => "Do we keep the old column?",
                  "options" => [%{"label" => "Keep"}, %{"label" => "Drop"}]
                }
              ]
            },
            frame
          )

        refute response.isError, inspect(response)

        # No tick. Anything the main agent has now, it was given.
        {:ok, context}
      end

      then_ "it is with the main agent already", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        assert html =~ "Do we keep the old column?",
               """
               The question is waiting for the next check-in.

               True, cheap, and it turns every blocked agent's wait into a whole
               interval — twenty minutes by default, paid by an agent that
               cannot do anything else in the meantime.

               Adding a timer is exactly what tempts an implementation to lean
               on it, which is why this criterion exists on the cadence's story
               as well as on story 1053's.

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
