defmodule CodeMySpecSpex.Story554.Criterion5095Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5095 — Total response size is hard-capped.

  The full `reason` string is capped at 4 KB. When blocking problems
  would exceed the cap, later problems are omitted with a tail footer
  `... more problems omitted (response size limit)`. The response body
  fits under the cap.

  Fixture `pipeline_overflow_4kb/`:
  - `compile.jsonl` — 15 long-message compiler warnings (one source).
  - `exunit.json` — 15 long-message exunit failures (second source).

  With `compile_warnings: :block` + `exunit: :block_all`, both sources
  are fully blocking. Each rendered line is near the 200-char
  per-problem cap, so two sources × 10 lines × ~250 chars is well
  above 4 KB — enough to trip the total cap.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_overflow_4kb"

  @total_cap 4096

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Total response size is hard-capped at 4 KB" do
    scenario "overflowing content is truncated with a size-limit footer" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "compile_warnings=block and exunit=block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{compile_warnings: "block", exunit: "block_all"}
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
        :ok
      end

      then_ "the reason fits under the 4 KB cap", context do
        reason = context.response["reason"]

        assert is_binary(reason)

        assert byte_size(reason) <= @total_cap,
               "reason must fit under #{@total_cap} bytes, got #{byte_size(reason)}"

        :ok
      end

      then_ "a size-limit footer is appended when content overflows", context do
        reason = context.response["reason"]

        assert reason =~ "response size limit",
               "overflow footer must mention the response size limit, got tail:\n#{String.slice(reason, -300, 300)}"

        assert reason =~ ~r/omitted/i,
               "overflow footer must indicate omissions, got tail:\n#{String.slice(reason, -300, 300)}"

        :ok
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
