defmodule CodeMySpecSpex.Story538.Criterion5110Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5110 — When continuous mode is off and the current task
  passes, the stop is allowed.

  Covers Rule R2: "Continuous mode is a flag on the session. When the
  flag is off, the stop is allowed and no continuation logic runs."

  The default for a freshly-created session is `continuous: false`,
  so the absence of a `start_implementation` skill invocation gives us
  the "continuous off" branch.

  ## Distinction from 555's spex

  555's spex assert specific pipeline behaviors (compile fails → block,
  no changes → skip, manual task → allow, etc.). This spex asserts the
  *continuation-logic gate itself*: with continuous off, the stop hook
  does not call `next_actionable` and does not embed a continuation
  directive, regardless of whether the graph has more work. If the
  gate were inverted, this spec would fail — there is more work in
  the graph (review_file, implementation_file, etc.) that the
  continuous-mode branch would surface as a block.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Continuous mode off, passing task, stop allowed" do
    scenario "the stop hook allows the stop without consulting the graph for continuation" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "continuous off must allow stop on a passing task — got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "no continuation directive is in the response body", context do
        refute Map.has_key?(context.response, "decision"),
               "continuous off should NOT produce a `decision` key — got: #{inspect(context.response)}"

        refute Map.has_key?(context.response, "reason"),
               "continuous off should NOT produce a `reason` key — got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
