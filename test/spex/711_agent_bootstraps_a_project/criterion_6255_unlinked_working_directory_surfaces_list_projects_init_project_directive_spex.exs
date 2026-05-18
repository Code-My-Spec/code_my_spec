defmodule CodeMySpecSpex.Story711.Criterion6255Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6255 — Unlinked working directory surfaces list_projects→init_project directive.

  When no `Project` row exists with `local_path` equal to the working
  directory, `Init.CliConfig.command/2` returns a prompt that
  instructs the agent to call `list_projects`, then `init_project`
  with the chosen project_id.

  Surface: `AgentTasks.Init.CliConfig.command/2`. The scope's cwd is
  swapped to a fresh tmp dir (one no Project row points at) so the
  unlinked branch fires.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.CliConfig is satisfied by a Project row whose local_path matches the working directory" do
    scenario "Unlinked working directory surfaces list_projects→init_project directive" do
      given_ "the local DB has no Project row with local_path equal to the working directory",
             context do
        unlinked_dir = Path.join(System.tmp_dir!(), "unlinked-#{System.unique_integer([:positive])}")
        File.mkdir_p!(unlinked_dir)
        ExUnit.Callbacks.on_exit(fn -> File.rm_rf(unlinked_dir) end)

        unlinked_scope = Map.put(context.scope, :cwd, unlinked_dir)
        {:ok, Map.put(context, :scope, unlinked_scope)}
      end

      when_ "the agent calls Init.CliConfig.command on the scope", context do
        {:ok, prompt} = Fixtures.init_cli_config_command(context.scope, %{})
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the prompt instructs the agent to call list_projects", context do
        assert context.prompt =~ ~r/list_projects/,
               "expected prompt to mention list_projects, got:\n#{context.prompt}"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to call init_project with the chosen project_id",
           context do
        assert context.prompt =~ ~r/init_project/,
               "expected prompt to mention init_project, got:\n#{context.prompt}"

        assert context.prompt =~ ~r/project_id/i,
               "expected prompt to mention the project_id parameter, got:\n#{context.prompt}"

        {:ok, context}
      end
    end
  end
end
