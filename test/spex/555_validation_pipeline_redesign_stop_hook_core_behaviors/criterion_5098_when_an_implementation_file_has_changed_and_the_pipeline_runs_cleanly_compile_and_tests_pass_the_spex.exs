defmodule CodeMySpecSpex.Story555.Criterion5098Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5098 — When an implementation file has changed and the
  pipeline runs cleanly (compile and tests pass), the stop is allowed.

  The happy path: agent writes a clean impl file under an active
  task, stop hook fires, pipeline runs `mix compile` (clean) +
  `mix test --stale` (no failures) via the shared `clean` cassette,
  no blocking problems, stop allowed.

  Reuses the `pipeline_clean_run` fixtures from 5101 (empty
  compile.jsonl + zero-failure exunit.json) and the existing
  `clean.json` cassette.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task with a clean pipeline run is allowed to stop" do
    scenario "agent writes a clean impl, pipeline runs clean, stop allowed" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent writes a fresh implementation and a passing test",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, impl())
        :ok = Environments.write_file(context.environment, @test_path, passing_test())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "clean pipeline run must allow the stop, got: #{inspect(context.response)}"

        :ok
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp impl do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end

  defp passing_test do
    """
    defmodule ExampleContextTest do
      use ExUnit.Case

      test "passes" do
        assert 1 == 1
      end
    end
    """
  end
end
