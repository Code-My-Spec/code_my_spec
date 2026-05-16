defmodule CodeMySpecSpex.Story711.Criterion6250Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6250 — Phoenix project shape in cwd satisfies Init.PhoenixProject.

  When the working directory contains `mix.exs`, `lib/`, AND `config/`,
  `Init.PhoenixProject.evaluate/2` returns `{:ok, :valid}`.

  Surface: `AgentTasks.Init.PhoenixProject.evaluate/2`. Pure
  filesystem check — no shell outs, no cassette.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.AgentTasks.Init

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.PhoenixProject requires mix.exs + lib/ + config/ in cwd; otherwise emits relaunch guidance" do
    scenario "Phoenix project shape in cwd satisfies Init.PhoenixProject" do
      given_ "the working directory contains mix.exs, lib/, and config/",
             context do
        File.mkdir_p!(Path.join(context.scope.cwd, "config"))
        # setup_active_project already seeded mix.exs and lib/
        {:ok, context}
      end

      when_ "the agent calls Init.PhoenixProject.evaluate on the scope",
            context do
        {:ok, Map.put(context, :evaluate_result, Init.PhoenixProject.evaluate(context.scope, %{}))}
      end

      then_ "the result is {:ok, :valid}", context do
        assert context.evaluate_result == {:ok, :valid},
               "expected {:ok, :valid}, got: #{inspect(context.evaluate_result)}"

        {:ok, context}
      end
    end
  end
end
