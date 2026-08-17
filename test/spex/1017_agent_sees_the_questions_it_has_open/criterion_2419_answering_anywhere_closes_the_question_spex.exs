defmodule CodeMySpecSpex.Story1017.Criterion2419Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2419 — Answering anywhere closes the question.

  The rule:

  > A question the user has answered is no longer open, however they answered it.

  ## The criterion originally named a page that cannot answer

  It read "the user answers it from the notifications inbox rather than the
  question's own page". `NotificationLive.Index` has no answer form — story 843
  criterion 1980 is "Clicking a pending question opens the answer page", so the
  inbox links and does not submit. A scenario driving it would have had to click
  through to `QuestionLive.Show`, which is the page the criterion was trying to
  avoid.

  The second real answering surface is `AgentConversationLive.Show`, which calls
  `Notifications.collect_answers/2` and `answer_question_request/2` itself —
  `collect_answers/2` says as much in its docs, and being submitted from two
  hosts is why it lives in the context rather than in a LiveView. Rewritten to
  say "a surface other than the question's own page", which is the rule.

  ## What is deliberately not asserted

  `e39b4eba` is the case where the user answers **in the terminal chat**. That
  reply reaches no record — there is no route from a terminal message to a
  `question_requests` row, and the issue lists building one as its largest
  option. So "however they answered it" is bounded here to answers that reach
  the record. Asserting the terminal case would be asserting a feature nobody
  has chosen to build, and would make this spec unpassable for reasons outside
  this story.

  What this story does own is the consequence: once an answer lands, the list
  must stop showing the question. A list that keeps returning answered questions
  reproduces `e39b4eba`'s harm — the agent chasing a reply it already has — at a
  new surface.

  ## Two questions, one answered

  Answering the only question would leave an empty list, and an empty list is
  what a broken tool returns too. Keeping one open means the assertion
  distinguishes "filters answered questions" from "returns nothing".

  ## Surface

  The MCP tool for the read. The answer goes through
  `POST /api/questions/:id/answer` on the cloud endpoint — the route that exists
  for clients that are not `QuestionLive`, which is exactly the "somewhere else"
  the rule is about.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.Fixtures

  @answered "Which approach do you want here?"
  @still_open "Should this ship behind a flag?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An answered question drops off the agent's list" do
    scenario "one of two questions is answered away from its own page" do
      given_ "a session exists for this working copy", context do
        session_id = "spex-2419-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent asked two questions", context do
        context = context |> ask_question(@answered) |> ask_question(@still_open)
        {:ok, context}
      end

      when_ "the user answers the first from a surface other than its own page", context do
        [answered_id | _] = context.question_ids

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{context.deploy_key}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          CodeMySpecWeb.Endpoint,
          :post,
          "/api/questions/#{answered_id}/answer",
          %{"answers" => %{@answered => "The second one."}}
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      then_ "the answered question is gone from the list", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)
        text = response_text(response)

        refute text =~ @answered,
               "the reply has landed, so the agent chasing it is the same waste " <>
                 "`e39b4eba` describes, arriving at a new surface. Got:\n#{text}"

        {:ok, Map.put(context, :text, text)}
      end

      then_ "the unanswered question is still listed", context do
        # Without this, a tool that returns nothing at all passes the refutation
        # above.
        assert context.text =~ @still_open,
               "only the answered question should have dropped off; an empty " <>
                 "list is what a broken tool returns. Got:\n#{context.text}"

        {:ok, context}
      end
    end
  end

  defp ask_question(context, text) do
    key = context[:deploy_key] || issue_deploy_key(context)

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

    context
    |> Map.put(:deploy_key, key)
    |> Map.update(:question_ids, [id], &(&1 ++ [id]))
  end

  defp issue_deploy_key(context) do
    key = "spex-deploy-key-#{System.unique_integer([:positive])}"
    Fixtures.project_with_deploy_key(context.scope, context.project, key)
    key
  end
end
