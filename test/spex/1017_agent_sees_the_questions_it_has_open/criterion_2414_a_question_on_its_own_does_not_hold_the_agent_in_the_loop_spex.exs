defmodule CodeMySpecSpex.Story1017.Criterion2414Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2414 — A question on its own does not hold the agent in the loop.

  The rule:

  > An unanswered question never blocks a stop.

  The load-bearing negative of this story. Everything else here makes open
  questions *visible*; this says visibility must not become a leash.

  ## Why the rule exists

  `check_answer` was once the top tier of the stop menu, ranked above problems,
  and story 894 demoted it to an unconditional offer for two reasons. One was
  ranking: a pending question is detectable but is not work in this working
  copy, so it cannot be ranked against work that is. The other was `e39b4eba` —
  a question answered anywhere other than `QuestionLive` never closes — which
  meant a single stale row could hold the top of the menu permanently.

  This criterion is the same failure one level up. If an open question could
  refuse a stop, one unanswered question would refuse *every* stop until a human
  happened to answer it on the right page, and an agent with nothing else to do
  would be pinned in the loop burning turns. That is worse than the churn 894
  was written to stop, because there is no work it could do to escape.

  So the count added by 2415 rides a refusal that some *other* class caused. It
  never causes one.

  ## The precondition is the whole scenario

  Everything must be satisfied before the question is asked, or the stop is
  refused for an unrelated reason and this proves nothing — the assertion would
  pass against a hook that blocks on questions, because something else blocked
  first. Same trap 2393 documents: two earlier attempts at a "nothing
  outstanding" given left requirements unsatisfied and passed anyway.

  Hence `FullSatisfactionFixtures.apply` and then nothing else except the
  question, because anything else set up here is work the menu would report.

  ## Surface

  Two endpoints, deliberately. The question is asked through
  `POST /api/questions/ask` on the cloud endpoint — the real path an unattended
  agent's question travels, behind `DeployKeyOrOAuth`, which is why the project
  needs a deploy key. The stop goes to `POST /api/hooks/stop` on the local
  endpoint. `~p` resolves against the local endpoint only, so the cloud call is
  dispatched explicitly.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An open question does not by itself refuse a stop" do
    scenario "a question is outstanding and no class of work is live" do
      given_ "every requirement in the graph is satisfied, so no class is live", context do
        {:ok, FullSatisfactionFixtures.apply(context)}
      end

      given_ "a session exists for this working copy", context do
        session_id = "spex-2414-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent asked the user a question and nobody has answered it", context do
        {:ok, ask_question(context, "Which approach do you want here?")}
      end

      when_ "the agent attempts to stop", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed", context do
        refute context.response["decision"] == "block",
               "an unanswered question must never refuse a stop. One question " <>
                 "nobody answers would otherwise pin the agent in the loop with " <>
                 "no work it could do to escape. Got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  # The real path an unattended agent's question takes: the cloud endpoint,
  # behind `DeployKeyOrOAuth`. Dispatched explicitly because `~p` in this module
  # resolves against `CodeMySpecLocalWeb.Endpoint`, where this route does not
  # exist.
  defp ask_question(context, text) do
    key = "spex-deploy-key-#{System.unique_integer([:positive])}"
    Fixtures.project_with_deploy_key(context.scope, context.project, key)

    %{"id" => id} =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(CodeMySpecWeb.Endpoint, :post, "/api/questions/ask", %{
        "questions" => [
          %{"question" => text, "header" => nil, "multiSelect" => false, "options" => []}
        ],
        "title" => "Claude has a message",
        "harness_id" => context.scope.active_harness_id
      })
      |> Phoenix.ConnTest.json_response(201)

    Map.put(context, :question_id, id)
  end
end
