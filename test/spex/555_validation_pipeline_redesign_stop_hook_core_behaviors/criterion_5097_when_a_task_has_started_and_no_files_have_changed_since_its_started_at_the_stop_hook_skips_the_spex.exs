defmodule CodeMySpecSpex.Story555.Criterion5097Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5097 — When a task has started and no files have changed
  since its started_at, the stop hook skips the pipeline (no compile,
  no analyzers, no tests) and the stop is allowed.

  Real-contract flow: `:synced_context_component` writes + syncs the
  component's files (updated_at T0), a 1.1-second clock advance
  guarantees the task's `started_at` lands past every file's
  updated_at, then `:context_spec_task_started` drives the actual
  `POST /api/hooks/session-start` + `start_task` MCP tool on the
  already-satisfied `spec_file` requirement. When the stop hook
  fires with no further writes, `Files.changed_since` returns [] and
  the pipeline short-circuits.

  No cassette needed — a missing one would fail the test if the
  pipeline tried to shell out.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task with no file changes skips the pipeline" do
    scenario "task started after sync, no writes follow, stop allowed" do
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
               "no-changes stop must skip the pipeline and allow, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
