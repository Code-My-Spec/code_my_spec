defmodule CodeMySpecSpex.Story554.Criterion5094Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5094 — Per-source enumeration is capped.

  Each source lists at most N blocking problems inline (cap: 10).
  Overflow surfaces as `... <remaining> more <source> problems (use
  get_issue to inspect)`.

  Fixture `pipeline_exunit_many_failures/exunit.json` has 15 exunit
  failures with distinct file paths. With `exunit: :block_all`, all 15
  are blocking; only 10 should appear inline, with a footer listing
  5 more.

  Reuses the `pipeline_exunit_failure` cassette — same `mix compile`
  + `mix test --stale` sequence, different JSON fixture.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_many_failures"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Per-source enumeration caps blocking problems at 10" do
    scenario "15 exunit failures render 10 inline plus an overflow footer" do
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

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked and the source header shows the full count",
            context do
        assert context.response["decision"] == "block"

        reason = context.response["reason"]

        assert reason =~ ~r/exunit\s*\(15\)/,
               "source header must show total count of 15, got:\n#{reason}"

        {:ok, context}
      end

      then_ "exactly 10 problem detail lines appear for exunit", context do
        reason = context.response["reason"]

        detail_lines =
          reason
          |> String.split("\n", trim: true)
          |> Enum.filter(fn line ->
            String.match?(line, ~r/^\s*-\s*test\/many_failures\//)
          end)

        assert length(detail_lines) == 10,
               "expected 10 enumerated exunit lines, got #{length(detail_lines)}:\n#{Enum.join(detail_lines, "\n")}"

        {:ok, context}
      end

      then_ "an overflow footer names the remaining count and the source",
            context do
        reason = context.response["reason"]

        assert reason =~ ~r/\.\.\.\s*5\s+more\s+exunit\s+problems/,
               "overflow footer must say '... 5 more exunit problems', got:\n#{reason}"

        assert reason =~ "get_issue",
               "overflow footer must point the agent at get_issue, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp failing_test do
    """
    defmodule ExampleContextTest do
      use ExUnit.Case
      test "fails" do
        assert 1 == 2
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
