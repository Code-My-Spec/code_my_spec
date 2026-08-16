defmodule CodeMySpecSpex.Story1015.Criterion2405Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2405 — A waiting answer withdraws the offer to ask.

  The rule:

  > Every refusal offers asking the user, unless an answer is already waiting.

  The exception to the standing offer, and the only one. Needing input is not a
  state the hook can detect, so `ask_user` is normally printed every time rather
  than gated on a condition nothing can evaluate. A waiting answer is the one
  condition that *is* visible — the row says so — and it is the one case where
  offering to ask is actively wrong: the reply to the last question is sitting
  unread, and asking another before reading it is how a queue fills with
  questions whose answers were already given.

  So the pair is: `check_answer` in, `ask_user` out. 2404 asserts the first
  half; this asserts the second, and they are separate criteria because a
  response could easily do one and not the other — naming the answer while still
  inviting a new question is the likely half-implementation.

  ## Why this runs with problems live

  A refusal is needed for the refutation to mean anything. On a clean tree the
  stop is allowed, the response carries no offers at all, and `refute reason =~
  "ask_user"` passes without proving a thing. So the setup is the same conflict
  as 2404 — a real compile failure and a real answered question — and what is
  asserted about it is different.

  ## Surfaces

  `POST /api/questions/ask` then `/answer`, both on `CodeMySpecWeb` behind
  `DeployKeyOrOAuth` and dispatched explicitly; the stop hook on
  `CodeMySpecLocalWeb` via `~p`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @deploy_key "dk_spex_894_offer_withdrawn"
  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"
  @question "Which of these should I do first?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The offer to ask is withdrawn while an answer is unread" do
    scenario "an answer is waiting and the stop is refused for something else" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding, so the stop is refused", context do
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

      then_ "the stop is refused, so the response carries offers at all", context do
        # The anchor. Without a refusal there is nothing to withdraw the offer
        # from, and the refutation below would pass against an empty string.
        assert context.response["decision"] == "block",
               "this scenario needs a refusal for the refutation to mean anything. " <>
                 "Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "asking the user is not offered", context do
        reason = context.response["reason"] || ""

        refute reason =~ "ask_user",
               "the reply to the last question is sitting unread, and inviting " <>
                 "another before it is read is how a queue fills with questions whose " <>
                 "answers were already given. Got:\n#{reason}"

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
