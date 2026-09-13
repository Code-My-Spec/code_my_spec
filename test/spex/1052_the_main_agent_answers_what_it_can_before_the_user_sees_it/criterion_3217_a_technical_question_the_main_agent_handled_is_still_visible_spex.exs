defmodule CodeMySpecSpex.Story1052.Criterion3217Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3217 — A technical question the main agent handled is still
  visible.

  The limit on 3218. That one removes the interruption; this says removing the
  interruption is not the same as removing the record.

  The distinction is between being *asked* and being able to *look*. Answering
  without interrupting is the product; answering invisibly is a main agent
  making decisions on the user's behalf that they cannot review, disagree with,
  or learn from — and 3220 and 3222, which let the user overrule, are
  unreachable if they never see it happened.

  It is also how the user learns what their agents are confused by. A list of
  questions the main agent quietly fielded is the clearest signal available
  about where the project's own records are thin.

  The answer has to be shown beside the question, not just the question:
  knowing something was asked and answered, without knowing what was said, is
  the same as not seeing it for every purpose except counting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias Ecto.Adapters.SQL.Sandbox

  @answer "the refunds epic is built on /tmp/refunds-copy"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Answering without interrupting is not the same as answering invisibly" do
    scenario "A technical question the main agent handled is still visible" do
      given_ "a coding agent asking which working copy its epic is built on", context do
        id = ask(context, "Which working copy is the refunds epic built on?", ["Tell me"])

        {:ok, Map.put(context, :question_id, id)}
      end

      given_ "the main agent answers it", context do
        reply = main_answers(context, context.question_id, @answer)

        refute reply.isError,
               "the premise is a question the main agent handled:\n#{response_text(reply)}"

        {:ok, context}
      end

      when_ "the user looks at their questions", context do
        {:reply, listed, _frame} = ListUserQuestions.execute(%{}, frame(context))

        {:ok, Map.put(context, :inbox, response_text(listed))}
      end

      then_ "that question is listed", context do
        assert context.inbox =~ "refunds epic",
               """
               A question the main agent fielded is invisible to the user.

               Removing the interruption is the product; removing the record is
               a main agent deciding on the user's behalf where they cannot
               review it. 3220 and 3222 let the user overrule an answer, and
               both are unreachable if they never see that one was given.

               It is also the clearest signal available about where the
               project's own records are thin — the things agents keep having
               to ask about.

               #{context.inbox}
               """

        {:ok, context}
      end

      then_ "and the answer is shown beside it", context do
        assert context.inbox =~ @answer,
               """
               The question is listed and what was said is not.

               Knowing something was asked and answered, without knowing what
               the answer was, is the same as not seeing it for every purpose
               except counting — and it is not enough to disagree with.

               #{context.inbox}
               """

        {:ok, context}
      end
    end
  end
end
