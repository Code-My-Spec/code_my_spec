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

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_overflow_4kb"

  @total_cap 4096

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Total response size is hard-capped at 4 KB", criterion: 136 do
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

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "the stop hook fires", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block"
        {:ok, context}
      end

      then_ "the reason fits under the 4 KB cap", context do
        reason = context.response["reason"]

        assert is_binary(reason)

        assert byte_size(reason) <= @total_cap,
               "reason must fit under #{@total_cap} bytes, got #{byte_size(reason)}"

        {:ok, context}
      end

      then_ "a size-limit footer is appended when content overflows", context do
        reason = context.response["reason"]

        assert reason =~ "response size limit",
               "overflow footer must mention the response size limit, got tail:\n#{String.slice(reason, -300, 300)}"

        assert reason =~ ~r/omitted/i,
               "overflow footer must indicate omissions, got tail:\n#{String.slice(reason, -300, 300)}"

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
