defmodule CodeMySpecSpex.Story1015.Criterion2404Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2404 — A waiting answer outranks problems.

  The rule:

  > Live classes are offered in a fixed order: an available answer, then
  > problems, then requirements.

  The top of the tier, and the only place the order is not obvious. Problems
  before requirements is easy to argue — do not start new work on a broken tree.
  An answer going first is the less obvious half, and John's reasoning is that
  it is the cheapest thing on the list and the one most likely to change what
  the right work *is*: an agent that fixes problems while an answer sits unread
  may be fixing something the answer would have told it to drop.

  So this is a scenario about a **conflict**. Both classes are genuinely live —
  a real compile failure and a real answered question — and only one of them can
  be the directive. Staging just the answer would prove the tier fires and not
  that it ranks.

  ## Surfaces — three, deliberately

  `POST /api/questions/ask` then `POST /api/questions/:id/answer`, both on
  `CodeMySpecWeb` behind `DeployKeyOrOAuth` and dispatched explicitly; the stop
  hook on `CodeMySpecLocalWeb` via `~p`, which binds that endpoint at compile
  time. The answer goes through the real endpoint rather than a status flip, so
  "waiting" means what the hook would have to read.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @deploy_key "dk_spex_894_answer_outranks"
  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"
  @question "Which of these should I do first?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An answer is collected before problems are fixed" do
    scenario "an answer is waiting and problems are live at the same time" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      given_ "the working copy holds a credential it can reach the API with", context do
        project = Fixtures.project_with_deploy_key(context.scope, context.project, @deploy_key)
        {:ok, Map.put(context, :project, project)}
      end

      given_ "the agent asked a question and the user answered it", context do
        %{"id" => id} =
          api_conn(context)
          |> Phoenix.ConnTest.dispatch(CodeMySpecWeb.Endpoint, :post, "/api/questions/ask", %{
            "questions" => [
              %{"question" => @question, "header" => nil, "multiSelect" => false, "options" => []}
            ],
            "title" => "Claude has a message",
            "harness_id" => context.scope.active_harness_id
          })
          |> Phoenix.ConnTest.json_response(201)

        %{"status" => "ok"} =
          api_conn(context)
          |> Phoenix.ConnTest.dispatch(
            CodeMySpecWeb.Endpoint,
            :post,
            "/api/questions/#{id}/answer",
            %{"answers" => %{@question => "Fix the problems last."}}
          )
          |> Phoenix.ConnTest.json_response(200)

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

      then_ "the agent is sent to the answer", context do
        reason = context.response["reason"] || ""

        assert reason =~ "check_answer",
               "an answer already waiting is the cheapest thing on the list and the " <>
                 "one most likely to change what the right work is. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the agent is not sent to the problems first", context do
        reason = context.response["reason"] || ""

        refute reason =~ "list_problems",
               "both classes are live, so offering both is not ranking them — and an " <>
                 "agent that fixes problems while an answer sits unread may be fixing " <>
                 "something the answer would have told it to drop. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp api_conn(context) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{@deploy_key}")
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
