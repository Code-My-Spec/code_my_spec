defmodule CodeMySpecSpex.Story1053.Criterion3265Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3265 — A question reaches the main agent without it going to look.

  Rule: a question is delivered, not discovered.

  Every other criterion on this story is about a list being right when somebody
  asks for it. This one says asking is not the only way it arrives, and it is
  the difference between the main agent being useful and being a report you have
  to run.

  Story 1059 gives the main agent a cadence — it wakes periodically and looks.
  That makes this criterion easy to mistake for already-satisfied: a question
  raised now *will* be seen, at the next tick. The criterion rules that out in
  its own words — "it does not wait for the main agent's next check-in" — and
  the scenario is built so a cadence cannot satisfy it: nothing wakes the main
  agent here except the question itself.

  The cost of getting it wrong is bounded but real: an agent blocked at the
  start of a cadence window waits the whole window for someone who was idle the
  entire time.

  Observed through the main agent's own conversation, which is where a delivered
  message lands. Not through the listing — a listing cannot distinguish
  "delivered" from "found when asked", which is the whole distinction.

  ## Why the question's text is not the assertion

  It was, and it passed with delivery ripped out. The conversation page carries
  a second thing beside the transcript: `waiting_for/2` renders every question
  pending for the *user*, on every conversation page, filtered only by session
  id — so an agent-raised question (which has none) appears on the main agent's
  page whether or not anything ever told it. The text was there for a reason
  that has nothing to do with this criterion.

  That is the listing the moduledoc above says not to read, arriving on the
  page the criterion does read. So the assertion is on the transcript entry
  instead: an orchestrator action of kind `question`, which exists only because
  something recorded a delivery onto this conversation. Both are asserted — the
  entry proves delivery happened here, the text proves it was this question.
  """

  use CodeMySpecSpex.Case

  # The conversation is a cloud-app surface; the case defaults to the local app,
  # where `live/2` answers 404 from inside LiveViewTest.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question is delivered rather than waited for" do
    scenario "a coding agent asks while the main agent is idle" do
      given_ "an idle main agent and a coding agent on the same project", context do
        reply = join_working_copy(context, "/tmp/spex-3265", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "main",
            working_copy: "/tmp/spex-3265"
          )

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3265"
          )

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:coding, coding)}
      end

      when_ "the coding agent asks a question", context do
        # Nothing else happens. No tick, no read, no look — so anything the main
        # agent knows afterwards, it was told.
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding.id}
        }

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              title: "asked while the main agent was idle",
              questions: [
                %{
                  "question" => "Do we drop the column or keep it nullable?",
                  "options" => [%{"label" => "Drop"}, %{"label" => "Keep"}]
                }
              ]
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "the main agent has been told, without having looked", context do
        {:ok, _live, html} =
          live(
            context.conn,
            CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope, context.main)
          )

        assert html =~ "An agent is waiting on an answer",
               """
               Nothing was delivered to the main agent's thread.

               Nothing in this scenario woke it or read anything, so if no entry
               was recorded on its conversation then the only way it would ever
               learn is by going to look — at its next cadence tick, which story
               1059 provides and which this criterion explicitly rules out.

               The cost is bounded and real: an agent blocked at the start of a
               window waits the whole window for someone who was idle
               throughout.

               Anchored on the sentence the main agent is sent rather than on
               the question's own text, because the page also renders every
               question pending for the *user* — which put that text on this
               page with delivery removed, and is why this does not assert it.

               It used to anchor on `data-action-kind="question"`, a marker of
               the orchestrator role. That role is gone: nothing wearing it was
               ever passed to a model, so this question was rendered for the
               person watching and never delivered to the agent the criterion is
               about. It is sent now, through the one path everything else that
               reaches an agent uses.
               """

        assert html =~ "Do we drop the column or keep it nullable?",
               "the main agent was told something, but not which question"

        {:ok, context}
      end
    end
  end
end
