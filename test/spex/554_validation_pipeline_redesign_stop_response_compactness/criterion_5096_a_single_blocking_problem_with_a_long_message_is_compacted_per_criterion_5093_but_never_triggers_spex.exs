defmodule CodeMySpecSpex.Story554.Criterion5096Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5096 — A single blocking problem is never overflow-truncated.

  A long raw message is compacted per 5093 (first line, truncated to
  ~200 chars), but one problem always fits under the 4 KB total cap —
  so the overflow footer from 5095 must NOT appear.

  Fixture `pipeline_exunit_long_message/exunit.json` contains one
  exunit failure whose `message` is ~279 characters on a single line.
  With `exunit: :block_all`, it's the sole blocking problem.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_long_message"

  @total_cap 4096
  @per_problem_cap 200

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A single blocking problem is compacted but never overflow-truncated" do
    scenario "one 279-char message truncates per 5093, no overflow footer" do
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
        assert context.response["decision"] == "block"
        {:ok, context}
      end

      then_ "the exunit line is compacted to roughly the per-problem cap",
            context do
        reason = context.response["reason"]

        exunit_line =
          reason
          |> String.split("\n", trim: true)
          |> Enum.find(fn line ->
            String.contains?(line, "test/long_message_test.exs")
          end)

        assert exunit_line, "reason must include the exunit failure line, got:\n#{reason}"

        # The rendered line is "  - file:line — <message truncated to cap>".
        # Allow modest overhead for the prefix/separator. Much > cap + 50
        # means truncation didn't happen.
        assert String.length(exunit_line) <= @per_problem_cap + 50,
               "exunit line must be compacted, got #{String.length(exunit_line)} chars:\n#{exunit_line}"

        assert exunit_line =~ "...",
               "compacted line must end with ellipsis indicating truncation, got:\n#{exunit_line}"

        {:ok, context}
      end

      then_ "no overflow footer is appended", context do
        reason = context.response["reason"]

        refute reason =~ "response size limit",
               "a single problem must not trigger the overflow footer, got:\n#{reason}"

        assert byte_size(reason) <= @total_cap,
               "reason must fit under #{@total_cap} bytes, got #{byte_size(reason)}"

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
