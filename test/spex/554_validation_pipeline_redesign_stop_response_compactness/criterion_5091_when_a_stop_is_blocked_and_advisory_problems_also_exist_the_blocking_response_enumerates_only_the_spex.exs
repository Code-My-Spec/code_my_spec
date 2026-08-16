defmodule CodeMySpecSpex.Story554.Criterion5091Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5091 — Advisory problems are summarized, not enumerated,
  when the stop is blocked.

  When a blocking response goes back to the agent, advisory problems
  collapse to one summary line per source: `<source>: N <severity>s
  (advisory)`. No individual advisory file paths, line numbers, or
  messages appear — the agent can't act on them this turn, and
  enumerating them wastes the context window.

  This spec drives a mixed state through the real pipeline:

  - **Blocking:** a compile warning on `lib/example_context.ex`. With
    `compile_warnings: :block`, any compiler diagnostic blocks.
  - **Advisory:** an exunit failure on the same file. With
    `exunit: :dont_block`, test failures are persisted but never
    blocking.

  Reuses the `pipeline_exunit_failure` cassette — the pipeline here
  runs `mix compile` (no errors, so continues) and `mix test --stale`,
  same as 5088/5089/5093. Credo is unavailable in the stub dir
  (`deps/credo` missing), so `Runner` short-circuits and no credo
  cassette entry is needed.

  Fixtures live under
  `test/fixtures/validation/pipeline_compile_block_exunit_advisory/`:

  - `compile.jsonl` — one warning diagnostic (hand-crafted).
  - `exunit.json` — one failure (copied from pipeline_exunit_failure).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_compile_block_exunit_advisory"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocking response summarizes advisory problems" do
    scenario "compile warning blocks while exunit failure is demoted to advisory" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "compile_warnings is set to block and exunit is set to dont_block",
             context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{compile_warnings: "block", exunit: "dont_block"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent writes an impl with an unused variable and a failing test",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, impl_with_unused())
        :ok = Environments.write_file(context.environment, @test_path, failing_test())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_exunit_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "compile_warnings=block must block on a compiler warning, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the blocking section enumerates the compiler warning",
            context do
        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        assert reason =~ "compiler",
               "blocking section must name the compiler source, got:\n#{reason}"

        assert reason =~ "lib/example_context.ex:2",
               "blocking section must include the warning file:line, got:\n#{reason}"

        assert reason =~ ~r/unused/i,
               "blocking section must include the warning message, got:\n#{reason}"

        {:ok, context}
      end

      then_ "the advisory section summarizes exunit as a single line with no detail",
            context do
        reason = context.response["reason"]

        assert reason =~ "Additional problems (not blocking):",
               "response must include an advisory header, got:\n#{reason}"

        advisory_block =
          reason
          |> String.split("Additional problems (not blocking):", parts: 2)
          |> List.last()

        assert advisory_block =~ ~r/^\s*-\s*exunit:\s*1\s/m,
               "advisory section must have a single 'exunit: 1 ...' summary line, got:\n#{advisory_block}"

        assert advisory_block =~ "(advisory)",
               "advisory line must be tagged (advisory), got:\n#{advisory_block}"

        refute advisory_block =~ "test/example_context_test.exs",
               "advisory section must not enumerate the exunit file path, got:\n#{advisory_block}"

        refute advisory_block =~ "exunit failure fixture",
               "advisory section must not include the exunit message body, got:\n#{advisory_block}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp impl_with_unused do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end

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
end
