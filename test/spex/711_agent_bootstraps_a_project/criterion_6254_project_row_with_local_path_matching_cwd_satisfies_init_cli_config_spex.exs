defmodule CodeMySpecSpex.Story711.Criterion6254Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6254 — Project row with local_path matching cwd satisfies Init.CliConfig.

  When the local DB contains a `Project` row whose `local_path` equals
  the working directory, `Init.CliConfig.evaluate/2` returns `{:ok,
  :valid}`.

  Surface: `AgentTasks.Init.CliConfig.evaluate/2`. The active project
  in `setup_active_project` is created with `local_path: stub_dir`,
  giving us exactly the row this contract asks for.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.CliConfig is satisfied by a Project row whose local_path matches the working directory" do
    scenario "Project row with local_path matching cwd satisfies Init.CliConfig" do
      given_ "the local DB contains a Project row whose local_path equals the working directory",
             context do
        # setup_active_project already inserted this row — assert here for clarity.
        assert context.project.local_path == context.scope.cwd,
               "expected setup_active_project to align local_path with cwd"

        {:ok, context}
      end

      when_ "the agent calls Init.CliConfig.evaluate on the scope", context do
        {:ok, Map.put(context, :evaluate_result, Fixtures.init_cli_config_evaluate(context.scope, %{}))}
      end

      then_ "the result is {:ok, :valid}", context do
        assert context.evaluate_result == {:ok, :valid},
               "expected {:ok, :valid}, got: #{inspect(context.evaluate_result)}"

        {:ok, context}
      end
    end
  end
end
