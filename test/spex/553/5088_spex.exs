defmodule CodeMySpecSpex.Story553.Criterion5088Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5088 — When exunit is set to block_changed, test failures on
  components outside the task's scope are persisted but do not block the stop.

  Exercises the blocking decision directly: seeds an exunit problem on a
  component that is NOT touched during this turn (no files changed since
  the task started), sets exunit to block_changed, fires the stop hook.
  The seeded problem should be advisory, not blocking.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets exunit to block_changed" do
    scenario "failures outside the task's scope don't block the stop" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "exunit is set to block_changed", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{exunit: "block_changed"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "an exunit failure exists on an untouched component", context do
        # No file changes this turn, so changed_component_ids will be [].
        # The seeded problem's component_id won't match, which is the whole
        # point — block_changed should treat it as advisory.
        Fixtures.problem_fixture(context.scope, %{
          source: "exunit",
          source_type: :test,
          severity: :error,
          file_path: "test/sessions_test.exs",
          line: 17,
          message: "expected 2, got 3",
          component_id: context.component.id
        })

        {:ok, context}
      end

      when_ "the stop hook fires with no file changes this turn", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed because the failure is outside task scope",
            context do
        assert context.response == %{},
               "block_changed must treat untouched-component failures as advisory, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
