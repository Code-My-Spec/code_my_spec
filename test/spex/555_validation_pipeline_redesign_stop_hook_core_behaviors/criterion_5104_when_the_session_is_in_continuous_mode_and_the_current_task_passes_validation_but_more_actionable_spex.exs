defmodule CodeMySpecSpex.Story555.Criterion5104Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5104 — When the session is in continuous mode and the
  current task passes validation but more actionable requirements
  exist in the graph, the stop is blocked with a get_next_requirement
  instruction.

  StopController's `maybe_continue_with_next_task/3` checks
  `state.continuous == true` + `RequirementGraph.next_actionable/1`
  returning a non-empty list. When both are true, it blocks with the
  instruction to call `get_next_requirement`.

  Real-contract flow: agent POSTs `/api/hooks/session-start` then
  POSTs `/api/agent-tasks/start` with `session_type=start_implementation`.
  `StartAgentTask.run_project_task/3` flips `state.continuous = true`
  on the session (fulfilling the `StartImplementation` @moduledoc
  promise). The session then has no active task (StartImplementation
  doesn't create one), so when the stop hook fires, task evaluation
  short-circuits valid on `Session.active_task == nil` and the
  continuous-mode branch is the path that runs.

  No pipeline cassette is needed: `:synced_context_component` gave
  the project a component with many unsatisfied requirements, so
  `next_actionable/1` has plenty of candidates to trigger the block.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Continuous mode blocks with next-task instruction" do
    scenario "continuous mode + more work available → block with get_next_requirement" do
      given_ :synced_context_component

      given_ "the agent signals session-start and starts implementation mode",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => external_id})
        |> Phoenix.ConnTest.json_response(200)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/agent-tasks/start", %{
          "external_id" => external_id,
          "session_type" => "start_implementation"
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, external_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with a get_next_requirement instruction",
            context do
        assert context.response["decision"] == "block",
               "continuous mode with more work must block the stop, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        assert reason =~ "get_next_requirement",
               "reason must direct the agent to call get_next_requirement, got:\n#{reason}"

        :ok
      end
    end
  end
end
