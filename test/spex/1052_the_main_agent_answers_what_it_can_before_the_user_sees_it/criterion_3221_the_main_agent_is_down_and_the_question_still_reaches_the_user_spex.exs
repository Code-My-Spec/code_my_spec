defmodule CodeMySpecSpex.Story1052.Criterion3221Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3221 — The main agent is down and the question still reaches the
  user.

  Putting the main agent in the path makes it a dependency, and this is the
  criterion that says it must not be a single point of failure.

  The main agent is the most likely of all of them to be down. It runs
  continuously, it restarts with the project's conversation, and story 1047's
  3186 argues it should be left alone when idle — so "main is not running" is
  an ordinary state this project is in regularly, not an edge case.

  Three Thens for three distinct ways this fails, in increasing cost. The
  question is invisible: the user cannot answer what they cannot see. The user
  sees it but cannot act: a listing is not a route. And the asking agent is
  blocked: one absent agent stops unrelated work on every other checkout, which
  is the failure that turns a degraded component into a stopped project.

  ## Surface

  "The question is still visible to the user" means visible on the user's own
  surface — `NotificationLive.Index` at `/app/notifications` — not
  `list_user_questions`, which is the *agent's* view of what it is waiting on
  and requires a harness session that nothing in this premise registers. A
  question with nobody to route it to still has to reach the person regardless
  of whether any agent happens to have a session open, which is exactly the
  case this criterion is about.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent is a router, not a single point of failure" do
    scenario "The main agent is down and the question still reaches the user" do
      given_ "no main agent running", context do
        roles = Enum.map(Fixtures.list_agents(context.scope), &to_string(&1.role))

        refute "main" in roles,
               "the premise is a project whose main agent is down, and one is running"

        {:ok, context}
      end

      when_ "an agent asks a question", context do
        id =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        {:ok, Map.put(context, :question_id, id)}
      end

      then_ "the question is still visible to the user", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               With the main agent down the question reaches nobody.

               The main agent is the most likely of them all to be down — it
               runs continuously, restarts with the project's conversation, and
               1047's 3186 argues it should be left alone when idle. This is an
               ordinary state, not an edge case, and routing through something
               that is regularly absent cannot mean stopping when it is.

               #{render(view)}
               """

        {:ok, context}
      end

      then_ "and the user can answer it", context do
        :ok = user_answers(context, context.question_id, "Refuse")

        answer = collect(context, context.question_id)

        assert answer =~ "Refuse",
               """
               The user could see the question and answering it did not reach
               the agent — a listing is not a route.

               #{answer}
               """

        {:ok, Map.put(context, :answer, answer)}
      end

      then_ "and the asking agent is not blocked waiting for the main agent to come back",
            context do
        refute context.answer =~ ~r/(waiting for the main|main agent is not running|unavailable)/i,
               """
               The asking agent is being told to wait on a component that is
               down.

               This is the most expensive of the three: one absent agent
               stopping unrelated work on every other checkout is what turns a
               degraded component into a stopped project.

               #{context.answer}
               """

        {:ok, context}
      end
    end
  end
end
