defmodule CodeMySpecSpex.Story711.Criterion6243Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6243 — First install copies every framework rule into .code_my_spec/rules/.

  When the working directory has no `.code_my_spec/rules/` and the agent
  calls `install_rules`, the tool creates the directory and copies every
  `.md` file from `priv/rules/` into it.

  Surface: `InstallRules` MCP tool. The tool reads from `priv/rules/`
  (via `Application.app_dir/2`) and writes to the real filesystem under
  `context.scope.cwd`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallRules

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_rules copies framework rule files from priv/rules/ into .code_my_spec/rules/" do
    scenario "First install copies every framework rule into .code_my_spec/rules/" do
      given_ "the working directory has no .code_my_spec/rules/ directory", context do
        rules_dir = Path.join([context.scope.cwd, ".code_my_spec", "rules"])
        File.rm_rf!(rules_dir)
        refute File.exists?(rules_dir), "expected rules dir to be absent before install"

        source_dir = Application.app_dir(:code_my_spec, "priv/rules")

        framework_rules =
          source_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".md"))

        assert framework_rules != [], "expected priv/rules to contain at least one .md file"

        {:ok, Map.merge(context, %{rules_dir: rules_dir, framework_rules: framework_rules})}
      end

      when_ "the agent calls install_rules", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallRules.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ ".code_my_spec/rules/ exists", context do
        assert File.dir?(context.rules_dir),
               "expected rules dir at `#{context.rules_dir}` after install"

        {:ok, context}
      end

      and_ "every .md file from priv/rules is present in the project's rules directory",
           context do
        for rule_file <- context.framework_rules do
          path = Path.join(context.rules_dir, rule_file)

          assert File.exists?(path),
                 "expected framework rule `#{rule_file}` at `#{path}` after install"
        end

        {:ok, context}
      end
    end
  end
end
