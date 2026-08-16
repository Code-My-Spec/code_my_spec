defmodule CodeMySpecSpex.Story1015.Criterion2402Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2402 — An unanswered question sends the agent to the answer.

  The rule:

  > A pending question directs the agent to collect the answer, not to ask again.

  A pending question is the one part of "the user owes me input" the hook can
  actually see, because asking wrote a row. Wanting to ask is an intention and
  invisible; having asked is a `question_requests` record with a status. That
  distinction is the whole reason this is a tiered directive while `ask_user` is
  only ever a standing offer.

  **Both tool descriptions already promise this and nothing implements it.**
  `ask_user` says "Do other work, or stop — the stop hook will bring you back.
  Call `check_answer` with that id for the reply", and `check_answer` says
  "stop, let the stop hook bring you back, and check again". Verified: the only
  file under `hooks/`, `validation/` or `problems/` that references
  `QuestionRequest` is `ask_user_question.ex`, which creates them. So an agent
  that follows the documented loop stops, the user answers, and nothing ever
  returns it.

  The second assertion is the one with teeth. Sending the agent to `ask_user`
  while a question is already outstanding is how a queue fills with the same
  question repeated — the exact failure that split the blocking `ask_user` into
  ask-then-check in the first place, when a transport timeout made each retry
  create another row while telling the agent the tool was broken.

  ## Surfaces — two endpoints, dispatched separately

  The question is created through the real API at `POST /api/questions/ask`,
  which lives on `CodeMySpecWeb` behind `DeployKeyOrOAuth`, so it is dispatched
  explicitly. The stop hook is on `CodeMySpecLocalWeb` and reached with `~p`,
  which binds that endpoint at compile time. A spec touching both cannot use
  `~p` for each.

  Authenticated with the project's deploy key rather than an OAuth token: that
  is the credential branch built for an agent with no browser, which is what
  this scenario is about.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @deploy_key "dk_spex_894_pending_question"
  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pending question sends the agent to collect the answer" do
    scenario "the agent asked, nobody has answered, and it tries to stop" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding, so the stop is refused", context do
        # Nothing reaches the model on the allow path — it must be an empty
        # response — so a directive is only observable on a refusal. The
        # question still outranks the problem; the problem is what makes the
        # ranking visible at all.
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      given_ "the working copy holds a credential it can reach the API with", context do
        project = Fixtures.project_with_deploy_key(context.scope, context.project, @deploy_key)

        {:ok, Map.put(context, :project, project)}
      end

      given_ "the agent asks the user a question", context do
        %{"id" => id} =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{@deploy_key}")
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(CodeMySpecWeb.Endpoint, :post, "/api/questions/ask", %{
            "questions" => [
              %{
                "question" => "Which of these should I do first?",
                "header" => nil,
                "multiSelect" => false,
                "options" => []
              }
            ],
            "title" => "Claude has a message",
            "harness_id" => context.scope.active_harness_id
          })
          |> Phoenix.ConnTest.json_response(201)

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent is sent to collect the answer", context do
        reason = context.response["reason"] || ""

        assert reason =~ "check_answer",
               "both tool descriptions promise the stop hook brings the agent back " <>
                 "for the reply. Nothing implemented it, so an agent that followed " <>
                 "them stopped and never returned. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the agent is not told to ask again", context do
        reason = context.response["reason"] || ""

        refute reason =~ "ask_user",
               "a question is already outstanding, and sending the agent to ask is " <>
                 "how one question becomes a queue of identical ones. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
