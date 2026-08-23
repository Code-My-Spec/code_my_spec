defmodule CodeMySpecSpex.Story538.Criterion5116Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5116 — When a manual-validation task completes and the
  human signals done but `evaluate_task` fails, the agent receives
  feedback and iterates on the same task.

  Covers Rule R4 (failure half): "failing evaluation iterates on the
  same task with feedback."

  ## Observable signals

  - `evaluate_task` returns a needs-work response with the checker's
    feedback so the agent knows what's missing.
  - The task does NOT transition to `:completed` — it stays active so
    the next stop hook still classifies it as an active manual task
    (and the agent can call evaluate_task again after iterating).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Manual task + failing evaluation → iterate with feedback" do
    scenario "evaluate_task returns needs-work; task stays in flight" do
      given_ :persona_research_task_started

      given_ "continuous mode is enabled (but the persona work is NOT done)", context do
        # Intentionally skip ProjectStateFixtures.apply_persona — the
        # PersonasChecker should find no personas (or missing files)
        # and return needs-work feedback.
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the unsatisfied manual task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "evaluate_task returns a needs-work response with feedback", context do
        body = TaskResponseHelpers.response_text(context.evaluate_response)

        refute context.evaluate_response.isError,
               "expected evaluate_task to succeed (returning needs-work, not an error), got: #{body}"

        assert body =~ ~r/needs.work|not yet|missing|feedback/i,
               "expected needs-work language in the response body, got:\n#{body}"

        {:ok, context}
      end

      and_ "the next stop hook still treats the manual task as in-flight (allows the stop)",
           context do
        # If the task were completed, the continuous-mode + actionable
        # branch would block. The "still active manual task" branch
        # short-circuits to allow — proving the task was NOT completed
        # by the failing evaluation.
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        assert response == %{},
               "expected the active manual task to keep the next stop allowing (iterate), got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
