defmodule CodeMySpecSpex.Story1058.Criterion3329Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3329 — Fiddling becomes an issue somebody can fix.

  Rule: a capability the system should have had is work, not a habit.

  Where 3315 is about the main agent noticing a *pattern*, this is about the
  single act: it worked around something an agent should have been able to do,
  and the workaround is recorded the moment it happens rather than when it has
  happened often enough to look like a pattern.

  Both exist because they fail differently. 3315's failure is a workaround that
  becomes permanent because nobody counts; this one's is a workaround that is
  never written down at all — and a system where the smoothing is invisible has
  no way to reach 3315's threshold, because there is nothing to count.

  ## `scope: framework`, and why that is the interesting part

  The criterion says "an issue against CodeMySpec" — not against the project
  being built. The gap is in the harness's own tool lists, and an issue filed
  against the customer's project would sit in a backlog whose owner cannot fix
  it and would be dismissed, teaching everybody to dismiss the next one.

  `create_issue`'s own documentation already says this is the rule: friction
  with the framework is a first-class issue rather than a question to escalate
  or a workaround to invent. This criterion is that rule applied to the main
  agent's own behaviour.

  ## "Can be triaged and built like any other work"

  Asserted as the issue being `incoming` — the state every issue starts in and
  the one triage reads from. An issue filed in some other state would be a
  private note in a public list.

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
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A workaround is written down where it can be picked up" do
    scenario "the main agent supplies something a role should have had" do
      given_ "a product agent blocked on something its tools do not expose",
             context do
        reply = join_working_copy(context, "/tmp/spex-3329", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # Something for the answer to rest on. The gap is that no *role* can
        # see it, not that the project does not record it.
        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3329")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "cannot see epic membership",
              questions: [
                %{
                  "question" => "Which ready story is not in an epic?",
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
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "it finishes working around the gap", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerNotification.execute(
            %{
              id: context.question_id,
              answer: "Dunning emails go out",
              basis: "record",
              worked_around: "no tool exposes story-to-epic membership"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "an issue describes the missing capability", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{scope: "framework"}, frame)

        assert response_text(issues) =~ ~r/epic/i,
               """
               The main agent worked around a capability an agent should have
               had and nothing records it.

               3315 counts a pattern; this is the single act, and without it
               there is nothing to count — a system where the smoothing is
               invisible can never reach 3315's threshold.

               `scope: framework`, because the gap is in the harness's own tool
               lists. Filed against the customer's project it would sit in a
               backlog whose owner cannot fix it and be dismissed, which teaches
               everybody to dismiss the next one.

               framework issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end

      then_ "and it can be triaged like any other work", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{status: "incoming"}, frame)

        assert response_text(issues) =~ ~r/epic/i,
               """
               The issue exists in some state triage does not read.

               "Can be triaged and built like any other work" is the criterion,
               and `incoming` is the state every issue starts in and the one
               triage reads from. Anywhere else it is a private note in a public
               list.

               incoming issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
