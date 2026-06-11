defmodule CodeMySpecSpex.Story711.Criterion6244Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6244 — Re-install preserves a user-modified rule file.

  When the project's `.code_my_spec/rules/` already contains a
  user-modified rule file (same filename as a framework default, but
  different content) and the agent calls `install_rules` again, the tool
  leaves the user-modified file untouched while still copying other
  framework rules that were absent.

  Surface: `InstallRules` MCP tool. The tool writes through
  `scope.environment`, so the spec seeds and reads rule files via
  `CodeMySpec.Environments`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallRules
  alias CodeMySpecSpex.Fixtures

  @rules_dir ".code_my_spec/rules"
  @user_marker "# USER-MODIFIED — do not overwrite\n"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_rules copies framework rule files from priv/rules/ into .code_my_spec/rules/" do
    scenario "Re-install preserves a user-modified rule file" do
      given_ "elixir.md in the project's rules dir holds user-written content distinct from the framework default",
             context do
        user_rule_path = Path.join(@rules_dir, "elixir.md")
        :ok = Environments.write_file(context.environment, user_rule_path, @user_marker)

        # Pick a framework rule we expect to land on this re-install. Any
        # .md file in priv/rules other than elixir.md will do.
        other_framework_rule =
          Fixtures.framework_rule_files()
          |> Enum.reject(&(&1 == "elixir.md"))
          |> List.first()

        assert other_framework_rule,
               "expected priv/rules to contain at least one .md file other than elixir.md"

        {:ok,
         Map.merge(context, %{
           user_rule_path: user_rule_path,
           other_framework_rule: other_framework_rule
         })}
      end

      when_ "the agent calls install_rules", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallRules.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "elixir.md still holds the user-written content", context do
        assert {:ok, contents} = Environments.read_file(context.environment, context.user_rule_path)

        assert contents == @user_marker,
               "expected user-modified elixir.md to be preserved, got:\n#{contents}"

        {:ok, context}
      end

      and_ "other framework rules absent before the call are now present", context do
        other_path = Path.join(@rules_dir, context.other_framework_rule)

        assert Environments.file_exists?(context.environment, other_path),
               "expected framework rule `#{context.other_framework_rule}` at `#{other_path}` after install"

        {:ok, context}
      end
    end
  end
end
