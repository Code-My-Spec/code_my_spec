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

  Two of the four real ones: the `ask_user` MCP tool to ask, and
  `POST /api/hooks/stop` to stop. An earlier draft dispatched
  `POST /api/questions/ask` on the cloud endpoint directly, which is not a
  surface a spex may drive — John: "you should only be driving the surface of
  the app through stop hooks, mcp tools, the ui, and files."

  That correction is what exposed the real gap. `ask_user` today hands off to
  `QuestionClient`, which makes an outbound HTTP call to the configured server,
  so it cannot run in-process and no spex has ever driven it. Asking is also
  still an *interception*: `Hooks.AskUserQuestion` denies Claude's native
  `AskUserQuestion` and returns the answer through the deny reason. Both are now
  this story's work — John: "part of this story should be to stop arbitraging
  Claude's ask user question and implement our own mcp tool."

  So this spec is red at the `given_` until that lands, which is the honest
  place for it to be red.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUser
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
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AskUser.execute(%{message: "Which approach do you want here?"}, frame)

        refute response.isError,
               "asking is the agent's own surface and has to work here. " <>
                 "Got: #{response_text(response)}"

        {:ok, Map.put(context, :question_id, question_id!(response))}
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

  # `ask_user` reports the id in prose, which is what the agent reads.
  defp question_id!(response) do
    body = response_text(response)

    case Regex.run(~r/Question id: ([0-9a-f-]{36})/, body) do
      [_, id] -> id
      _ -> raise "could not read a question id from: #{body}"
    end
  end
end
