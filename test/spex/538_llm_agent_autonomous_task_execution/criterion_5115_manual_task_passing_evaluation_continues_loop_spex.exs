defmodule CodeMySpecSpex.Story538.Criterion5115Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5115 — When a manual-validation task completes and the
  human signals done in conversation, the agent calls `evaluate_task`
  and on a passing evaluation the loop continues.

  Covers Rule R4: "validation_type: :manual tasks are checkpoints,
  not loop terminators. The human signals completion to the agent in
  conversation; the agent calls evaluate_task. Continuous mode
  resumes from the result of that evaluation — passing evaluation
  continues the loop."

  ## What "loop continues" looks like through the surface

  After `evaluate_task` returns passed (task transitions to
  `:completed`), the next stop hook fire in continuous mode should
  block with the next-requirement directive embedded (per 5111/5112).
  This spex drives the full cycle: kick off a manual task on
  `personas_complete`, plant the persona artifacts (the "human did
  the work" outcome), enable continuous mode, call `evaluate_task`,
  then fire the stop hook and assert the loop is still running.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Manual task + passing evaluation → loop continues" do
    scenario "evaluate_task passes, then the next stop blocks with next-requirement directive" do
      given_ :persona_research_task_started

      given_ "the human did the persona work (persona created + summary/sources written)",
             context do
        context = ProjectStateFixtures.apply_persona(context)
        {:ok, context}
      end

      given_ "continuous mode is enabled on this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the manual task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "evaluate_task returns a passed response", context do
        body = TaskResponseHelpers.response_text(context.evaluate_response)

        refute context.evaluate_response.isError,
               "expected evaluate_task to succeed, got: #{body}"

        assert body =~ ~r/pass|complet/i,
               "expected the response body to indicate a pass, got:\n#{body}"

        {:ok, context}
      end

      and_ "the subsequent stop hook fires in continuous mode and blocks with the next directive",
           context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        assert response["decision"] == "block",
               "expected continuous mode to keep the loop running after a passing manual eval, got: #{inspect(response)}"

        assert response["reason"] =~ "start_task",
               "expected the loop-continuation reason to embed a start_task directive, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
