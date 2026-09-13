defmodule CodeMySpecSpex.Story1052.Criterion3222Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3222 — A main agent that answers wrongly does not bury the
  question.

  3220 is the mechanism — a user's answer supersedes a main agent's. This is
  the *reachability* of it, from where the user actually stands.

  The distinction is the word "bury". An answered question is, by every
  ordinary rule, finished: it has an answer, nobody is waiting, and every
  listing that filters for open work correctly leaves it out. That is right for
  the ninety per cent the main agent gets right, and it is exactly what puts
  the wrong ones out of reach — the user would have to know to go looking for
  something nothing is telling them about.

  So this asserts the sequence a person actually performs: read the question
  and what was said, disagree, answer it themselves, and have that reach the
  agent. Read, then act, on the same surface. A design where reviewing is
  possible but correcting needs a different route satisfies 3217 and 3220
  separately and leaves the user with no way through.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias Ecto.Adapters.SQL.Sandbox

  @wrong "Allow — I can find no record of a refund window."

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An answer the user disagrees with is reachable from where they stand" do
    scenario "A main agent that answers wrongly does not bury the question" do
      given_ "the main agent answered with something the user disagrees with", context do
        id =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        reply = main_answers(context, id, @wrong)

        refute reply.isError,
               "the premise is an answered question:\n#{response_text(reply)}"

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the user reads the question and its answer", context do
        {:reply, listed, _frame} = ListUserQuestions.execute(%{}, frame(context))

        {:ok, Map.put(context, :inbox, response_text(listed))}
      end

      then_ "they can answer it themselves", context do
        assert context.inbox =~ "refunds older than ninety days",
               """
               The answered question is not in front of the user at all, so
               there is nothing to disagree with.

               An answered question is by every ordinary rule finished — it has
               an answer and nobody is waiting — which is right for the ones
               the main agent gets right and is exactly what puts the wrong
               ones out of reach. The user would have to know to go looking for
               something nothing is telling them about.

               #{context.inbox}
               """

        assert context.inbox =~ @wrong,
               """
               The question is visible and the answer the user is supposed to
               disagree with is not shown, so there is nothing to disagree
               with.

               #{context.inbox}
               """

        :ok = user_answers(context, context.question_id, "Refuse")

        {:ok, context}
      end

      then_ "and the agent receives the corrected answer", context do
        answer = collect(context, context.question_id)

        assert answer =~ "Refuse",
               """
               The user corrected the answer and the agent is still holding the
               wrong one.

               Reviewing and correcting have to work from the same place. A
               design where reading is possible but correcting needs a
               different route satisfies 3217 and 3220 separately and leaves
               the user with no way through.

               #{answer}
               """

        {:ok, context}
      end
    end
  end
end
