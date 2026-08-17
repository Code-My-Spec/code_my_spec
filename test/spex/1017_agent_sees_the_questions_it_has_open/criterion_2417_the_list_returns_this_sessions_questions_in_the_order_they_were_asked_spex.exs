defmodule CodeMySpecSpex.Story1017.Criterion2417Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2417 — The list returns this session's questions in the order they
  were asked.

  The rule:

  > An agent can list the questions it asked in this session.

  ## The tool this drives does not exist yet

  `list_user_questions` is the deliverable. `ask_user` and `check_answer` are
  registered in `LocalServer`; nothing lists. So this spec is red until the tool
  is written, which is the point — the criterion is the specification, not a
  description of today.

  The name was settled in the Three Amigos session: `list_questions` is taken by
  `BddRules.Tools.ListQuestions`, the Three Amigos red cards, and an agent sees
  both in one tool list. `user` is what separates a question asked *of the user*
  from a red card parked against a story.

  ## The domain half is already built

  `Notifications.list_question_requests_for_session/1` is the query and already
  orders `asc: :inserted_at`; `Sessions.external_id_for_harness/1` turns the
  agent's harness into the session key, which is how `QuestionController.ask`
  already stamps a question on the way in. The tool has to join those two — the
  agent's scope carries a harness, never a session.

  ## Why order is asserted rather than membership

  A set of two questions tells the agent what is outstanding but not which it
  left hanging longest, and the natural reading of an unordered list is
  most-recent-first — the opposite of what the query returns. Asserting both are
  present would pass against either order and leave the disagreement between the
  tool and the query to be discovered later.

  ## Surface

  The MCP tool directly, which is how an agent reaches it. Questions are asked
  through `POST /api/questions/ask` on the cloud endpoint, dispatched
  explicitly — `~p` here resolves against `CodeMySpecLocalWeb.Endpoint`. The
  session is created through the real `session-start` hook, because a question
  is only tied to a conversation if a session with that harness exists when it
  is asked.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.Fixtures

  @first "Which approach do you want here?"
  @second "Should this ship behind a flag?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent can see what it has asked, oldest first" do
    scenario "two questions were asked in this session" do
      given_ "a session exists for this working copy", context do
        session_id = "spex-2417-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent asked two questions, oldest first", context do
        context = context |> ask_question(@first) |> ask_question(@second)
        {:ok, context}
      end

      when_ "the agent lists its questions", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the list is returned without error", context do
        refute context.response.isError,
               "listing is a read; it has no failure mode here. " <>
                 "Got: #{response_text(context.response)}"

        {:ok, context}
      end

      then_ "both questions are listed", context do
        text = response_text(context.response)

        assert text =~ @first, "the older question is missing. Got:\n#{text}"
        assert text =~ @second, "the newer question is missing. Got:\n#{text}"

        {:ok, context}
      end

      then_ "the older question comes first", context do
        text = response_text(context.response)

        assert :binary.match(text, @first) < :binary.match(text, @second),
               "oldest first is what tells the agent which question it has left " <>
                 "hanging longest; most-recent-first is the natural default and " <>
                 "the opposite of what the query returns. Got:\n#{text}"

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
