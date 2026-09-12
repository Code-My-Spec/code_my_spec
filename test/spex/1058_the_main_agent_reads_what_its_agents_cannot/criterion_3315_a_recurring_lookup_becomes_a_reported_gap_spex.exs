defmodule CodeMySpecSpex.Story1058.Criterion3315Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3315 — A recurring lookup becomes a reported gap.

  Rule: a workaround that keeps working is a design, and nobody designed it.

  The failure this prevents is the most comfortable one in the story, because
  everything works. The agent asks, the main agent answers, the work carries on
  — every time, forever. Nothing is broken and nothing is written down, and the
  role quietly acquires a permanent dependency on somebody else looking things
  up for it.

  It is worse than a gap that blocks. A gap that blocks gets fixed; a gap that
  is smoothly worked around is invisible to everyone except the thing doing the
  smoothing, and the thing doing the smoothing is not going to get tired.

  ## Several, not one

  One lookup is the main agent doing its job — that is criterion 3314 and it
  must not file anything, or the issue list fills with successful work. The
  claim here is about a *pattern*, so the scenario asks three times and asserts
  nothing was filed until the pattern existed.

  ## Who notices

  The main agent says what it had to work around; the counting is the system's.
  That split is the criterion's own — "when the main agent notices the pattern"
  — and it is the only one that works: whether an answer was a workaround or
  ordinary knowledge is a judgement only the thing that made it holds, and
  inferring it from the question's text would be guessing at intent from prose.

  ## The gap is reported against the role, not the question

  "A gap in that role's tools" is the criterion's own phrasing, and it is what
  makes the issue actionable: somebody reading it needs to know which tool list
  to add to, not merely that a question was asked three times.

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
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @question "Which ready story is not in an epic?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A lookup the main agent keeps doing is written down as a gap" do
    scenario "a product agent needs the same lookup three times" do
      given_ "a product agent that has needed it twice already", context do
        reply = join_working_copy(context, "/tmp/spex-3315", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # Something for the answer to rest on. The gap is that no *role* can
        # see it, not that the project does not record it.
        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        agent = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3315")

        for _occasion <- 1..2 do
          answer_one(scope, agent)
        end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "it needs it again and the main agent notices the pattern", context do
        answer_one(context.scope, context.agent)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        {:ok, Map.put(context, :issues, response_text(issues))}
      end

      then_ "the missing capability is reported as a gap in that role's tools",
            context do
        assert context.issues =~ ~r/product/i,
               """
               The main agent has now done the same lookup for the product role
               three times and nothing says so.

               This is the comfortable failure: the agent asks, the main agent
               answers, the work carries on — every time, forever. Nothing is
               broken and nothing is written down, and the role acquires a
               permanent dependency on somebody else looking things up for it.

               It is worse than a gap that blocks. A gap that blocks gets fixed;
               one that is smoothly worked around is invisible to everybody
               except the thing doing the smoothing, which is not going to get
               tired of it.

               issues:
               #{context.issues}
               """

        assert context.issues =~ ~r/epic/i,
               """
               A gap is reported without saying what is missing.

               "The product role keeps needing help" tells somebody a pattern
               exists and nothing about what to build. The criterion asks for
               the missing *capability*, which is what makes the issue work
               somebody can pick up.

               issues:
               #{context.issues}
               """

        {:ok, context}
      end
    end
  end

  # One round of the pattern: the agent asks, the main agent answers.
  defp answer_one(scope, agent) do
    asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    {:reply, asked, _frame} =
      AskUserQuestion.execute(
        %{
          title: "cannot see epic membership",
          questions: [
            %{"question" => @question, "options" => [%{"label" => "A"}, %{"label" => "B"}]}
          ]
        },
        asking
      )

    question_id = Fixtures.question_id_from(response_text(asked))
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, _answered, _frame} =
      AnswerQuestion.execute(
        %{
          question_id: question_id,
          answer: "Dunning emails go out",
          basis: "record",
          worked_around: "no tool exposes story-to-epic membership"
        },
        frame
      )

    :ok
  end
end
