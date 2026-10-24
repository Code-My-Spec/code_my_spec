defmodule CodeMySpecSpex.Story554.Criterion5092Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 5092 — Advisory problems do not appear in an allow response.

  When the stop is allowed and the only problems in the DB are
  advisory, the response body is the allow signal (an empty JSON
  object). No advisory file paths, messages, or summary lines reach
  the agent's context through the response.

  The advisory is still persisted (Story 553 criterion 5089 covers
  that). This spec is about what the *agent sees* — the formatter
  policy, not the persistence policy.

  Reuses the `pipeline_exunit_failure` cassette + JSON fixtures. Since
  2026-10-18 no problem blocks a stop, so the recorded exunit failure is
  information like any other and the stop is allowed.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Allow response contains no advisory problem text", criterion: 133 do
    scenario "a recorded failure does not reach the allow response" do
      given_ :synced_context_component

      given_ "the agent writes a failing test file", context do
        :ok = ExecutionContexts.write_file(context.execution_context, @test_path, failing_test())
        :ok = ExecutionContexts.write_file(context.execution_context, @impl_path, impl())
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

      then_ "the response is the empty allow signal", context do
        assert context.response == %{},
               "allow response must be an empty map, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "no advisory field (reason/decision/problems) appears in the response",
            context do
        refute Map.has_key?(context.response, "reason"),
               "allow response must not include a reason field, got: #{inspect(context.response)}"

        refute Map.has_key?(context.response, "decision"),
               "allow response must not include a decision field, got: #{inspect(context.response)}"

        refute Map.has_key?(context.response, "problems"),
               "allow response must not include a problems field, got: #{inspect(context.response)}"

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
