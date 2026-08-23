defmodule CodeMySpecSpex.Story1017.Criterion2419Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2419 — An answered question drops off the agent's list.

  The rule:

  > A question the user has answered is no longer open, however they answered it.

  ## The criterion has been narrowed twice, and both times for a reason

  It first said the user answers "from the notifications inbox".
  `NotificationLive.Index` has no answer form — story 843 criterion 1980 is
  "Clicking a pending question opens the answer page" — so the inbox links
  rather than submits, and a scenario driving it would have had to click through
  to the page the criterion was trying to avoid.

  It then said "a surface other than the question's own page", driven by
  `POST /api/questions/:id/answer`. That is not a surface a spex may drive.
  John: "you should only be driving the surface of the app through stop hooks,
  mcp tools, the ui, and files." The remaining not-its-own-page surface is
  `AgentConversationLive.Show`, which needs a whole conversation to exist before
  a question can be answered in it — setup that would dominate a scenario whose
  subject is the list.

  So it now says "in the web app" and drives `QuestionLive.Show`, which is the
  page a user actually answers on.

  What is lost by narrowing is worth stating: this no longer proves that *every*
  answering surface closes a question. It proves the consequence this story owns
  — once an answer lands, the list stops showing it. The unclosed cases belong
  to `e39b4eba`, which is specifically the user answering in the terminal chat,
  where no route from a message to a `question_requests` row exists at all.

  ## Two questions, one answered

  Answering the only question would leave an empty list, and an empty list is
  what a broken tool returns too. Keeping one open makes the assertion
  distinguish "filters answered questions" from "returns nothing".

  ## Surface

  Three of the four real ones: `ask_user` and `list_user_questions` as MCP
  tools, and `QuestionLive.Show` as the UI. `@endpoint` is the cloud endpoint so
  `live/2` reaches `/app`, which means the session-start hook — on
  `CodeMySpecLocalWeb` — has to be dispatched explicitly rather than through
  `~p`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUser
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions

  @endpoint CodeMySpecWeb.Endpoint

  @answered "Which approach do you want here?"
  @still_open "Should this ship behind a flag?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An answered question drops off the agent's list" do
    scenario "one of two questions is answered in the web app" do
      given_ "a session exists for this working copy", context do
        session_id = "spex-2419-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          CodeMySpecLocalWeb.Endpoint,
          :post,
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent asked two questions", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        ids =
          for text <- [@answered, @still_open] do
            {:reply, response, _frame} = AskUser.execute(%{message: text}, frame)

            refute response.isError,
                   "asking is the agent's own surface and has to work here. " <>
                     "Got: #{response_text(response)}"

            question_id!(response)
          end

        {:ok, Map.put(context, :question_ids, ids)}
      end

      when_ "the user answers the first one in the web app", context do
        [answered_id | _] = context.question_ids

        {:ok, view, _html} = live(context.conn, "/app/questions/#{answered_id}")

        view
        |> form("[data-test='question-form']", %{"q_0" => "The second one."})
        |> render_submit()

        {:ok, context}
      end

      then_ "the answered question is gone from the list", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)
        text = response_text(response)

        refute text =~ @answered,
               "the reply has landed, so an agent still chasing it is the same " <>
                 "waste `e39b4eba` describes, arriving at a new surface. " <>
                 "Got:\n#{text}"

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

  # `ask_user` reports the id in prose, which is what the agent reads.
  defp question_id!(response) do
    body = response_text(response)

    captured!(Regex.run(~r/Question id: ([0-9a-f-]{36})/, body), body)
  end

  # Two heads rather than a `case`, following 958's `captured!/2`: imperative
  # `case` is banned in spex files, and a bare match would throw away the
  # haystack — `Regex.run/2` returns nil, so the MatchError says only "nil".
  defp captured!([_, id], _body), do: id
  defp captured!(_no_match, body), do: raise("could not read a question id from: #{body}")
end
