defmodule CodeMySpecSpex.Story555.Criterion5097Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5097 — When a task has started and no files have changed
  since its started_at, the stop hook skips the pipeline (no compile,
  no analyzers, no tests) and the stop is allowed.

  After `:synced_context_component` syncs the story's files, we start
  an active task with `started_at` set 10s in the future. When the
  stop hook fires, `Validation.resolve_changed_files/3` calls
  `Files.changed_since(scope, task.started_at)` — every synced file's
  `updated_at` is earlier than `started_at`, so the changed-files set
  is empty, `run_pipeline/5` short-circuits, and the stop is allowed.

  No cassette is needed. If the short-circuit broke and the pipeline
  tried to run `mix compile`, the test would fail on a missing
  cassette.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task with no file changes skips the pipeline" do
    scenario "task started after sync, no writes follow, stop allowed" do
      given_ :synced_context_component

      given_ "a session has an active task started after the last sync",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        # 10s in the future guarantees task.started_at > every
        # synced file's updated_at, even after second-truncation.
        future =
          DateTime.utc_now()
          |> DateTime.add(10, :second)
          |> DateTime.truncate(:second)

        session =
          Fixtures.session_with_task_fixture(
            context.scope,
            %{external_conversation_id: external_id},
            %{started_at: future}
          )

        {:ok, Map.merge(context, %{session: session, external_id: external_id})}
      end

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.external_id})
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
