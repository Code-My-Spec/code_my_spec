defmodule CodeMySpecSpex.Story553.Criterion5088Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5088 — When exunit is set to block_changed, test failures on
  components outside the task's scope are persisted but do not block the
  stop.

  End-to-end: two turns of the stop hook.

  Turn 1 writes a failing test file; the pipeline records an exunit
  problem (via the `pipeline_exunit_failure` cassette + JSON fixture).
  Turn 2 fires the stop hook with no file changes — FileSync reports
  no changes, the pipeline is skipped, and `check_blocking_problems`
  consults the persisted problem with `block_changed` config and empty
  `changed_component_ids`, demoting it to advisory.

  We only assert on turn 2; turn 1 is setup. The cassette and fixtures
  are shared with 5089 (same failing test path).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

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

      given_ "turn 1: the agent writes a failing test and fires the stop hook",
             context do
        :ok = Environments.write_file(context.environment, @test_path, failing_test())
        :ok = Environments.write_file(context.environment, @impl_path, impl())

        _turn_1_response =
          use_cmd_cassette "pipeline_exunit_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, context}
      end

      when_ "turn 2: the stop hook fires with no file changes", context do
        # Second turn: no writes since turn 1, so FileSync reports no
        # changes and the pipeline is skipped. No System.cmd is invoked,
        # so no cassette wrapper is needed.
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed because the failure is outside task scope",
            context do
        assert context.response == %{},
               "block_changed must treat untouched-component failures as advisory, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp failing_test do
    """
    defmodule ExampleContextTest do
      use ExUnit.Case

      test "fails on purpose" do
        assert 1 == 2, "exunit failure fixture"
      end
    end
    """
  end

  defp impl do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end
end
