defmodule CodeMySpecSpex.Story711.Criterion6248Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6248 — Successful version probe satisfies a prereq sub-step.

  When `Init.Elixir.evaluate/2` runs against a toolchain that reports
  Elixir 1.18 or higher via `elixir --version`, the sub-step returns
  `{:ok, :valid}`.

  Surface: `AgentTasks.Init.Elixir.evaluate/2`. ExCliVcr replays
  `init_elixir_pass.json` so the assertion doesn't depend on the test
  host having a specific Elixir version installed.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prereq sub-steps satisfy on a successful version-probe shell out" do
    scenario "Successful version probe satisfies a prereq sub-step" do
      given_ "the active toolchain reports an Elixir version of 1.18 or higher",
             context do
        {:ok, context}
      end

      when_ "the agent calls Init.Elixir.evaluate on the scope", context do
        result =
          use_cmd_cassette "init_elixir_pass", record: :none do
            Fixtures.init_elixir_evaluate(context.scope, %{})
          end

        {:ok, Map.put(context, :evaluate_result, result)}
      end

      then_ "the result is {:ok, :valid}", context do
        assert context.evaluate_result == {:ok, :valid},
               "expected {:ok, :valid}, got: #{inspect(context.evaluate_result)}"

        {:ok, context}
      end
    end
  end
end
