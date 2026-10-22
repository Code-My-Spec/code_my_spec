defmodule CodeMySpecSpex.Story554.Criterion1913Spex do
  @moduledoc """
  Story 554 — Validation Pipeline Redesign: Stop Response Compactness
  Criterion 1913 — A stop's response never reports or waits on analysis that
  is still running; it speaks only from persisted problems.

  Title-only criterion; no scenario was recorded against it. Driven directly
  from the title: an analyzer (spex) is left with no landed result at all —
  genuinely still running, from the stop's point of view — while an earlier
  exunit/compiler run has already landed its problems. The stop answers from
  those persisted problems alone: it neither blocks waiting on the
  still-running analyzer nor names it in the response.

  Reuses the `pipeline_exunit_failure` cassette + JSON fixtures from the
  sibling spec (criterion 133). Since 2026-10-18 no problem blocks a stop, so
  the landed exunit failure does not change the decision — what this spec
  checks is that the still-unlanded spex run is simply absent from the
  response, not reported as pending.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop answers from persisted problems alone, never waiting on or naming a still-running analyzer",
    criterion: 1913 do
    scenario "the spex analyzer has landed no result yet when the stop fires" do
      given_ :synced_context_component

      given_ "the agent writes a failing test file", context do
        :ok = Environments.write_file(context.environment, @test_path, failing_test())
        :ok = Environments.write_file(context.environment, @impl_path, impl())
        {:ok, context}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "exunit and compiler have already landed their problems, but spex has landed nothing",
             context do
        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response = HarnessHooks.post_hook(context, "stop", %{})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response answers now, from what is already persisted", context do
        assert context.response == %{},
               "the stop must answer immediately from persisted problems, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the still-running spex analyzer is never named or waited on in the response", context do
        refute Map.has_key?(context.response, "waiting"),
               "the response must not report a wait on the still-running analyzer, got: #{inspect(context.response)}"

        refute Map.has_key?(context.response, "pending"),
               "the response must not name a pending/running analyzer, got: #{inspect(context.response)}"

        refute Map.has_key?(context.response, "spex"),
               "the response must not reference the still-running spex analyzer by name, got: #{inspect(context.response)}"

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
