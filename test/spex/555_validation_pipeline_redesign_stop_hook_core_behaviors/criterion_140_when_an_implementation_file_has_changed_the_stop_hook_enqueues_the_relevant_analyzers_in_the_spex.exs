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

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active task with a clean pipeline run is allowed to stop", criterion: 140 do
    scenario "agent writes a clean impl, pipeline runs clean, stop allowed" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "the agent writes a fresh implementation and a passing test",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, impl())
        :ok = record_edit(context, @impl_path)
        :ok = Environments.write_file(context.environment, @test_path, passing_test())
        :ok = record_edit(context, @test_path)
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "clean pipeline run must allow the stop, got: #{inspect(context.response)}"

        {:ok, context}
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
