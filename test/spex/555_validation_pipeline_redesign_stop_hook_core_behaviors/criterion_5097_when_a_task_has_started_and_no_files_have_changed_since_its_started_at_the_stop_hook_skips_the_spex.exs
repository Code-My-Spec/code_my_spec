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

  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task with no file changes skips the pipeline" do
    scenario "task started after sync, no writes follow, stop allowed" do
      given_ :synced_context_component

      given_ "enough clock time passes that the task's started_at will land past every file's updated_at",
             context do
        # Files.changed_since uses `updated_at >= since`. Sync just
        # ran; a task started in the same second would match every
        # synced file. Crossing a second boundary makes
        # `started_at > updated_at` deterministic.
        Process.sleep(1_100)
        {:ok, context}
      end

      given_ :context_spec_task_started

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "no-changes stop must skip the pipeline and allow, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
