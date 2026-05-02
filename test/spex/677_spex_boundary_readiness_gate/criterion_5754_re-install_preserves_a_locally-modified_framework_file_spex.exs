defmodule CodeMySpecSpex.Story677.Criterion5754Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5754 — Re-install preserves a locally-modified framework file.

  Rule: `install_credo_checks` is idempotent — existing files are never
  overwritten on re-run.

  If a project edits a framework Credo check (for example, to add an
  app-specific module to the deny list as a temporary measure before
  the proper local check is in place), re-running
  `install_credo_checks` must leave that edit intact. The framework
  default in `priv/credo_checks/` is the canonical source on FIRST
  install only — once a file is on disk in the project, the project
  owns it.

  Surface: `InstallCredoChecks` MCP tool. The tool writes to the real
  filesystem under `context.scope.cwd`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks

  @custom_marker "# PROJECT EDIT — do not overwrite\n"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Re-install preserves a locally-modified framework file" do
    scenario "framework file already present with project-specific content → re-install leaves content untouched" do
      given_ "the framework directory exists with a locally-modified spex_denied_calls.ex",
             context do
        framework_dir = Path.join(context.scope.cwd, ".code_my_spec/credo_checks/framework")
        :ok = File.mkdir_p!(framework_dir)

        path = Path.join(framework_dir, "spex_denied_calls.ex")
        :ok = File.write!(path, @custom_marker)

        {:ok, Map.put(context, :spex_denied_calls_path, path)}
      end

      when_ "the agent calls install_credo_checks again", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallCredoChecks.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "spex_denied_calls.ex still contains the project-specific edit", context do
        content = File.read!(context.spex_denied_calls_path)

        assert content == @custom_marker,
               "expected file content to be preserved as `#{inspect(@custom_marker)}`, got: #{inspect(content)}"

        {:ok, context}
      end
    end
  end
end
