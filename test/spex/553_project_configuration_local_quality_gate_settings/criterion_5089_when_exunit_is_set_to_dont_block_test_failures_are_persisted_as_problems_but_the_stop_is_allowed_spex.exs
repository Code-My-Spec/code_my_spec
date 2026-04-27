defmodule CodeMySpecSpex.Story553.Criterion5089Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5089 — When exunit is set to dont_block, test failures are
  persisted as problems but the stop is allowed regardless.

  End-to-end: the agent writes a failing test file, the stop hook fires,
  `mix test --stale` records an exunit failure on the touched component
  (via the `pipeline_exunit_failure` cassette + JSON fixture), and the
  `dont_block` config demotes the problem to advisory.

  ## Recording this cassette

  See `.code_my_spec/knowledge/spex/recording_cassettes.md` for the full
  recipe. Summary:

  1. In `../code_my_spec_test_repo/`, write a failing test file at
     `test/test_phoenix_project/example_context_test.exs`.
  2. Capture the ExUnit JSON output:

         EXUNIT_JSON_OUTPUT_FILE=/tmp/exunit_failure.json \\
           mix test --formatter ClientUtils.TestFormatter --stale

         cp /tmp/exunit_failure.json \\
            ../code_my_spec/test/fixtures/validation/pipeline_exunit_failure/exunit.json

  3. Capture a clean compile JSONL the same way, into
     `test/fixtures/validation/pipeline_exunit_failure/compile.jsonl`.
  4. Delete the old cassette, flip `record: :once` here temporarily,
     run the spec, then flip back to `:none`.
  5. Remove the failing test file from the test repo and commit.
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

      given_ "the agent writes a failing test file", context do
        :ok = Environments.write_file(context.environment, @test_path, failing_test())
        :ok = Environments.write_file(context.environment, @impl_path, impl())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_exunit_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed regardless of the exunit failure", context do
        assert context.response == %{},
               "dont_block must allow the stop even when failures exist, got: #{inspect(context.response)}"

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
