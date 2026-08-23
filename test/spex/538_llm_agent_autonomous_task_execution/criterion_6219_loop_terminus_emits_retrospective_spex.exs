defmodule CodeMySpecSpex.Story538.Criterion6219Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 6219 — Loop terminus emits a retrospective prompt.

  Covers R7 (terminus retrospective): when the autonomous loop ends
  via R6 (graph empty, continuous on), the stop response carries a
  structured `retrospective` marker with a prompt and a scope hint
  pointing the agent at `create_issue` with `scope: framework` for
  harness friction observed during the run.

  Mirrors 5120's R6 terminus setup; the extra observation is the new
  R7 payload on the same response.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "R6 terminus emits an R7 retrospective marker on the stop response" do
    scenario "graph empty + continuous on → response carries a retrospective with framework scope hint" do
      given_ "every requirement in the graph is satisfied so the actionable set is empty",
             context do
        context = FullSatisfactionFixtures.apply(context)
        {:ok, context}
      end

      given_ "a session exists with continuous mode enabled and no active task", context do
        session_id = "spex-6219-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        :ok = Fixtures.start_continuous_mode(context.scope, session_id)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the stop hook fires at the loop terminus", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed (no block decision)", context do
        refute context.response["decision"] == "block",
               "R6 terminus must allow the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the response carries an R7 retrospective marker with a prompt", context do
        retrospective = context.response["retrospective"]

        assert is_map(retrospective),
               "expected response to carry a `retrospective` map, got: #{inspect(context.response)}"

        prompt = retrospective["prompt"]

        assert is_binary(prompt) and prompt != "",
               "expected the retrospective to include a non-empty prompt, got: #{inspect(retrospective)}"

        {:ok, context}
      end

      then_ "the retrospective points at the framework-issue surface", context do
        retrospective = context.response["retrospective"]

        assert retrospective["scope"] == "framework",
               "expected the retrospective scope hint to be `framework`, got: #{inspect(retrospective)}"

        assert retrospective["prompt"] =~ ~r/create_issue/i,
               "expected the retrospective prompt to name create_issue, got: #{inspect(retrospective["prompt"])}"

        assert retrospective["prompt"] =~ ~r/framework/i,
               "expected the retrospective prompt to mention framework scope, got: #{inspect(retrospective["prompt"])}"

        {:ok, context}
      end
    end
  end
end
