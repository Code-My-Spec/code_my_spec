defmodule CodeMySpecSpex.Story677.Criterion5753Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5753 — First install copies framework checks into the project.

  Rule: Framework Credo checks are installed via the `install_credo_checks`
  MCP tool, which is idempotent — existing files are never overwritten.

  When the agent calls `install_credo_checks` against a project with no
  `.code_my_spec/credo_checks/` directory, the tool creates the
  `framework/` and `local/` directories and copies the framework Credo
  check files (`spex_denied_calls.ex` and `no_direct_send_in_spex.ex`)
  from `priv/credo_checks/` into the project's framework directory.

  Surface: `InstallCredoChecks` MCP tool. The tool writes through
  `scope.environment`, so the spec observes the in-memory environment via
  `CodeMySpec.Environments`. The in-memory store tracks files, not empty
  directories, so the "local/ is empty" expectation is observed as "no
  framework files leaked into local/".
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks

  @framework_dir ".code_my_spec/credo_checks/framework"
  @local_dir ".code_my_spec/credo_checks/local"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "First install copies framework checks into the project" do
    scenario "no .code_my_spec/credo_checks/ directory exists → install creates and populates it" do
      given_ "the project has no .code_my_spec/credo_checks/ directory under the working directory",
             context do
        assert {:ok, []} =
                 Environments.list_directory(context.environment, ".code_my_spec/credo_checks"),
               "expected credo_checks to be empty before install"

        {:ok, context}
      end

      when_ "the agent calls install_credo_checks", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallCredoChecks.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "spex_denied_calls.ex exists under credo_checks/framework/", context do
        path = Path.join(@framework_dir, "spex_denied_calls.ex")

        assert Environments.file_exists?(context.environment, path),
               "expected framework check at `#{path}` after install"

        {:ok, context}
      end

      and_ "no_direct_send_in_spex.ex exists under credo_checks/framework/", context do
        path = Path.join(@framework_dir, "no_direct_send_in_spex.ex")

        assert Environments.file_exists?(context.environment, path),
               "expected framework check at `#{path}` after install"

        {:ok, context}
      end

      and_ "no framework files leak into credo_checks/local/", context do
        assert {:ok, []} = Environments.list_directory(context.environment, @local_dir),
               "expected `#{@local_dir}/` to stay empty"

        {:ok, context}
      end
    end
  end
end
