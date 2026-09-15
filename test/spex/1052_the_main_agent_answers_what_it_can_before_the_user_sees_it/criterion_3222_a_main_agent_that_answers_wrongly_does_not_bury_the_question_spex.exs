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

  ## Surface, and why the wrong answer cites something real

  "They can answer it themselves" is driven on `QuestionLive.Show` itself —
  the same page the read happens on — rather than a fixture, because the
  criterion's whole point is whether a route exists from reading to
  correcting. Before this criterion, `ChatComponents.question/1` dropped the
  form the moment a question was answered; there was no route back, by any
  surface, once the main agent had spoken. Driving a fixture here would have
  hidden exactly that.

  The wrong answer is built the same way 3220's is: it names a real checkout
  (`checkout_of/2`) and draws a policy conclusion that does not follow, rather
  than asserting an absence — an unsupportable answer never reaches the state
  this criterion is about, because `answer_question(basis: "record")` refuses
  it first.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

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

        wrong_answer = "Allow — refunds already run without a window on #{checkout_of(context, id)}"
        reply = main_answers(context, id, wrong_answer)

        refute reply.isError,
               "the premise is an answered question:\n#{response_text(reply)}"

        {:ok, context |> Map.put(:question_id, id) |> Map.put(:wrong_answer, wrong_answer)}
      end

      when_ "the user reads the question and its answer", context do
        {:ok, view, _html} = live(context.conn, "/app/questions/#{context.question_id}")

        {:ok, Map.put(context, :question_view, view)}
      end

      then_ "they can answer it themselves", context do
        rendered = render(context.question_view)

        assert rendered =~ "refunds older than ninety days",
               """
               The answered question is not in front of the user at all, so
               there is nothing to disagree with.

               An answered question is by every ordinary rule finished — it has
               an answer and nobody is waiting — which is right for the ones
               the main agent gets right and is exactly what puts the wrong
               ones out of reach. The user would have to know to go looking for
               something nothing is telling them about.

               #{rendered}
               """

        assert rendered =~ context.wrong_answer,
               """
               The question is visible and the answer the user is supposed to
               disagree with is not shown, so there is nothing to disagree
               with.

               #{rendered}
               """

        context.question_view
        |> form("main [data-test='question-form']", %{"q_0" => "Refuse"})
        |> render_submit()

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
