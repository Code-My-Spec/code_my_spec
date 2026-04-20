defmodule CodeMySpecSpex.Story554.Criterion5093Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5093 — Blocking problem messages are compacted to one line.

  When a blocking problem's raw message contains a multi-line body
  (stacktrace, assertion left/right dump, etc.), the formatted stop
  response must render it as a single line: `file:line — first line of
  message, truncated to ~200 chars`. The agent can inspect the full
  problem via `get_issue` or the LiveView; the stop reason is not the
  place to reproduce it.

  Reuses the `pipeline_exunit_failure` cassette + JSON fixtures
  recorded for Story 553 specs 5088/5089. The seeded exunit message
  contains `\\ncode: ...\\nstacktrace: ...` — ripe for compaction.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocking response compacts multi-line problem messages" do
    scenario "exunit failure with stacktrace renders as a single compact line" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "exunit is set to block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{exunit: "block_all"}
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

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "block_all must block on an exunit failure, got: #{inspect(context.response)}"

        :ok
      end

      then_ "the exunit entry is a single line with file, line, and first message line",
            context do
        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        exunit_line =
          reason
          |> String.split("\n", trim: true)
          |> Enum.find(fn line ->
            String.contains?(line, "test/example_context_test.exs")
          end)

        assert exunit_line,
               "reason must contain a line referencing the failing test file, got:\n#{reason}"

        assert exunit_line =~ ~r/test\/example_context_test\.exs:\d+/,
               "exunit entry must include file:line, got: #{exunit_line}"

        assert exunit_line =~ "exunit failure fixture",
               "exunit entry must include the first line of the assertion message, got: #{exunit_line}"

        :ok
      end

      then_ "the compacted line strips stacktrace and multi-line body",
            context do
        reason = context.response["reason"]

        refute reason =~ ~r/stacktrace:/i,
               "compacted reason must not contain 'stacktrace:', got:\n#{reason}"

        refute reason =~ ~r/^code:/m,
               "compacted reason must not contain the 'code:' assertion dump, got:\n#{reason}"

        :ok
      end

      then_ "the compacted line stays under the per-problem length cap",
            context do
        reason = context.response["reason"]

        exunit_line =
          reason
          |> String.split("\n", trim: true)
          |> Enum.find(fn line ->
            String.contains?(line, "test/example_context_test.exs")
          end)

        assert String.length(exunit_line) <= 250,
               "compacted exunit entry must be <= 250 chars, got #{String.length(exunit_line)}: #{exunit_line}"

        :ok
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
