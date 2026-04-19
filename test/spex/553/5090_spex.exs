defmodule CodeMySpecSpex.Story553.Criterion5090Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5090 — When an engineer enables spex, any spex failure blocks
  the stop hook.

  `spex` defaults to `:off`, which means the source is never consulted by
  the blocking check. When the engineer flips it to `:block_all`, spex
  problems become blocking.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer enables spex" do
    scenario "a spex failure blocks the stop when spex is block_all" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "spex is set to block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spex: "block_all"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "a spex failure exists on a synced file", context do
        # Seed the problem against a file that is present in the in-memory
        # env — FileSync.sync_changed wipes problems for missing files on
        # every run, so the file_path must be one the sync will find.
        Fixtures.problem_fixture(context.scope, %{
          source: "spex",
          source_type: :test,
          severity: :error,
          file_path: "lib/example_context.ex",
          line: 15,
          message: "expected document to contain \"hello\"",
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

      then_ "the stop is blocked with the spex failure", context do
        assert context.response["decision"] == "block",
               "spex :block_all must block on any spex failure, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ ~r/spex/i,
               "block reason must mention spex, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
