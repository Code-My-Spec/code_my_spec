defmodule CodeMySpecSpex.Story1058.Criterion3330Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3330 — The same workaround is not filed over and over.

  Rule: a gap is one thing however many times it bites.

  3329's necessary companion. A main agent that files on every workaround and
  never checks produces a backlog where one missing tool appears forty times,
  and the effect is not merely untidy — it is that the list stops being read.
  Triage that opens on forty copies of the same thing learns to skim, and the
  next real issue is skimmed with them.

  It is the same shape as story 1056's repeat-suppressed restart and for the
  same reason: an automated actor with no sense of "I have already said this"
  will say it as often as the trigger fires, and the trigger here fires every
  time an agent hits a gap nobody has got round to closing.

  ## Recurrence is recorded, not discarded

  The criterion's second half, and the more useful one. "Do not file again"
  alone would throw away the fact that it happened three more times — which is
  exactly the evidence that decides whether this gap is worth closing before the
  next thing. So the existing issue has to say so.

  That is also what distinguishes this from simple deduplication: a system that
  silently dropped the second report would satisfy the first half and leave
  triage with one data point and no idea it was the tip of anything.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @gap "no tool exposes story-to-epic membership"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One gap is one issue, however often it bites" do
    scenario "the same missing capability is worked around twice more" do
      given_ "an issue already filed for the gap", context do
        reply = join_working_copy(context, "/tmp/spex-3330", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3330")

        work_around(scope, agent)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent works around it again", context do
        work_around(context.scope, context.agent)
        work_around(context.scope, context.agent)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{scope: "framework"}, frame)

        {:ok, Map.put(context, :issues, response_text(issues))}
      end

      then_ "it does not file a second issue for the same gap", context do
        filed = context.issues |> String.split("\n") |> Enum.count(&(&1 =~ ~r/epic/i))

        assert filed == 1,
               """
               The same missing capability has been filed #{filed} times.

               One missing tool appearing forty times in a backlog is not merely
               untidy: triage that opens on forty copies of one thing learns to
               skim, and the next real issue is skimmed with them.

               Same shape as story 1056's repeat-suppressed restart, and the
               same reason — an automated actor with no sense of "I have already
               said this" says it as often as the trigger fires, and this
               trigger fires every time an agent hits a gap nobody has closed.

               framework issues:
               #{context.issues}
               """

        {:ok, context}
      end

      then_ "and the existing issue says it has happened again", context do
        assert context.issues =~ ~r/3 times|three times|\b3\b/,
               """
               The repeats were dropped rather than recorded.

               "Do not file again" on its own throws away the fact that it
               happened twice more, which is exactly the evidence that decides
               whether this gap is worth closing before the next thing. Silent
               deduplication satisfies the first half of the criterion and
               leaves triage with one data point and no idea it is the tip of
               anything.

               framework issues:
               #{context.issues}
               """

        {:ok, context}
      end
    end
  end

  defp work_around(scope, agent) do
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

    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, _answered, _frame} =
      AnswerQuestion.execute(
        %{
          question_id: Fixtures.question_id_from(response_text(asked)),
          answer: "the one about dunning emails",
          worked_around: @gap
        },
        frame
      )

    :ok
  end
end
