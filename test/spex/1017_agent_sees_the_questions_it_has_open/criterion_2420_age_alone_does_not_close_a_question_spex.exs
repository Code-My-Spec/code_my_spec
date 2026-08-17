defmodule CodeMySpecSpex.Story1017.Criterion2420Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2420 — Age alone does not close a question.

  The rule:

  > A question stays open until it is answered.

  This is the no-expiry decision stated as behaviour. `expired` is currently a
  legal status — `QuestionRequest` declares `~w(pending answered expired)` and
  both `QuestionClient.poll/3` and `CheckAnswer` have branches for it — with no
  writer anywhere in production. Only the spex fixtures manufacture it, and
  `expire_question/1` says so outright: "There is no public call for this."

  The Three Amigos session chose to delete the status and its dead reader
  branches rather than build the TTL that would justify them. So this criterion
  guards against the other direction: somebody seeing the orphaned `expired`
  branch later and implementing a sweeper to make it reachable.

  ## "A long time ago" is encoded as "across repeated stops", and that is a
  ## deliberate weakening

  A spex has no clock. `Date.now`-style travel is not available here, and
  back-dating `inserted_at` means a direct write to the row — a fixture in a
  `given_`, asserting against manufactured state rather than driven state.

  What the rule actually guards is not the passage of time as such; it is a
  *sweeper* — something that runs and decides a question has been open too long.
  The moment such a thing would plausibly run is a stop, which is the only
  recurring server-side event in an agent's life. So the scenario stops twice
  and asserts the question is still there.

  This is weaker than a genuine age test and it should be read as what it is: it
  catches a sweeper wired into the stop path, and it would not catch a
  background job on a timer. If expiry is ever implemented, this criterion is
  the one that has to be revisited, not quietly deleted.

  ## Surface

  The MCP tool for the read; `POST /api/hooks/stop` for the events in between.
  No cassette and no `test_output_files` — nothing has changed on disk, so there
  is nothing for an analyzer to run, and staging output would add a class of
  work the scenario is not about.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.Fixtures

  @question "Which approach do you want here?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unanswered question survives everything except an answer" do
    scenario "the agent stops repeatedly and nobody ever answers" do
      given_ "a session exists for this working copy", context do
        session_id = "spex-2420-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent asked a question and nobody answered it", context do
        {:ok, ask_question(context, @question)}
      end

      when_ "the agent stops twice without the question being answered", context do
        stop(context)
        stop(context)

        {:ok, context}
      end

      then_ "the question is still listed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)
        text = response_text(response)

        assert text =~ @question,
               "nothing answered it, so nothing should have closed it. A " <>
                 "question that ages out silently is a decision the user never " <>
                 "made disappearing from the one place they would see it. " <>
                 "Got:\n#{text}"

        {:ok, Map.put(context, :text, text)}
      end

      then_ "it is not reported as expired", context do
        refute context.text =~ ~r/expired/i,
               "`expired` is a status nothing writes and the Three Amigos " <>
                 "session chose to delete rather than implement; a list " <>
                 "reporting it means a sweeper was added. Got:\n#{context.text}"

        {:ok, context}
      end
    end
  end

  defp stop(context) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
    |> Phoenix.ConnTest.json_response(200)
  end

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

    context |> Map.put(:deploy_key, key) |> Map.put(:question_id, id)
  end
end
