defmodule CodeMySpecSpex.Story553.Criterion5090Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5090 — When an engineer enables spex, any spex failure blocks
  the stop hook.

  `spex` defaults to `:off`, which means the source is never consulted by
  the blocking check. When the engineer flips it to `:block_all`, spex
  problems become blocking.

  End-to-end: the agent starts a `WriteBddSpecs` task (via the real
  session_start hook + `start_task` MCP tool), writes a failing BDD spec
  file, fires the stop hook. The task's `analyzers/0` returns
  `[:spex_stale]`, so the pipeline runs `mix spex --stale` (replayed
  from the `pipeline_spex_failure` cassette + JSONL fixture), records a
  spex problem, and `block_all` blocks.

  ## Recording this cassette

  See `.code_my_spec/framework/bdd/spex/recording_cassettes.md`. Summary:

  1. In `../code_my_spec_test_repo/`, write a failing BDD spec at
     `test/spex/failing_example_spex.exs`.
  2. Capture the JSONL output:

         mix spex test/spex/failing_example_spex.exs \\
           --jsonl=/tmp/spex_failure.jsonl

         cp /tmp/spex_failure.jsonl \\
            ../code_my_spec/test/fixtures/validation/pipeline_spex_failure/spex.jsonl

  3. Capture a clean compile JSONL into
     `test/fixtures/validation/pipeline_spex_failure/compile.jsonl`.
  4. Delete the old cassette, flip `record: :once` temporarily, run the
     spec, flip back to `:none`.
  5. Remove the failing spec file from the test repo and commit.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @spex_path "test/spex/example_context_spex.exs"

  @fixture_dir "test/fixtures/validation/pipeline_spex_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer enables spex" do
    scenario "a spex failure blocks the stop when spex is block_all" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex is set to block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spex: "block_all"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent writes a failing BDD spec file", context do
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => fixture_path("spex.jsonl"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with the spex failure", context do
        assert context.response["decision"] == "block",
               "spex :block_all must block on any spex failure, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ ~r/spex/i,
               "block reason must mention spex, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "intentional failure" do
        scenario "asserts false" do
          then_ "fails", _context do
            assert 1 == 2, "spex failure fixture"
            {:ok, _context}
          end
        end
      end
    end
    """
  end
end
