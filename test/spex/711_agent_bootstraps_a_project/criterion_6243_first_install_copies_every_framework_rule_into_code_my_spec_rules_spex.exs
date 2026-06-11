defmodule CodeMySpecSpex.Story711.Criterion6243Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6243 — First install copies every framework rule into .code_my_spec/rules/.

  When the working directory has no `.code_my_spec/rules/` and the agent
  calls `install_rules`, the tool creates the directory and copies every
  `.md` file from `priv/rules/` into it.

  Surface: `InstallRules` MCP tool. The tool reads from `priv/rules/`
  (via `Application.app_dir/2`) and writes through `scope.environment`, so
  the spec observes the in-memory environment via `CodeMySpec.Environments`.
  The canonical framework rule list comes from `Fixtures.framework_rule_files/0`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallRules
  alias CodeMySpecSpex.Fixtures

  @rules_dir ".code_my_spec/rules"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_rules copies framework rule files from priv/rules/ into .code_my_spec/rules/" do
    scenario "First install copies every framework rule into .code_my_spec/rules/" do
      given_ "the working directory has no .code_my_spec/rules/ directory", context do
        assert {:ok, []} = Environments.list_directory(context.environment, @rules_dir),
               "expected rules dir to be empty before install"

        framework_rules = Fixtures.framework_rule_files()

        assert framework_rules != [], "expected priv/rules to contain at least one .md file"

        {:ok, Map.put(context, :framework_rules, framework_rules)}
      end

      when_ "the agent calls install_rules", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallRules.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ ".code_my_spec/rules/ now contains rule files", context do
        assert {:ok, entries} = Environments.list_directory(context.environment, @rules_dir)

        assert entries != [], "expected rules dir to contain files after install"

        {:ok, context}
      end

      and_ "every .md file from priv/rules is present in the project's rules directory",
           context do
        for rule_file <- context.framework_rules do
          path = Path.join(@rules_dir, rule_file)

          assert Environments.file_exists?(context.environment, path),
                 "expected framework rule `#{rule_file}` at `#{path}` after install"
        end

        {:ok, context}
      end
    end
  end
end
