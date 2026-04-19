defmodule CodeMySpecSpex.Story553.Criterion5089Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5089 — When exunit is set to dont_block, test failures are
  persisted as problems but the stop is allowed regardless.

  `dont_block` is the escape hatch for work-in-progress: the engineer still
  wants test results recorded (so the UI surfaces them) but doesn't want the
  agent halted. Unlike `block_changed` (5088), `dont_block` allows the stop
  even when the failure IS on a touched component.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets exunit to dont_block" do
    scenario "failures on the touched component still don't block" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "exunit is set to dont_block", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{exunit: "dont_block"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "an exunit failure exists on the touched component", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "exunit",
          source_type: :test,
          severity: :error,
          file_path: "lib/example_context.ex",
          line: 42,
          message: "assertion failed",
          component_id: context.component.id
        })

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed regardless of the exunit failure", context do
        assert context.response == %{},
               "dont_block must allow the stop even when failures exist, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
