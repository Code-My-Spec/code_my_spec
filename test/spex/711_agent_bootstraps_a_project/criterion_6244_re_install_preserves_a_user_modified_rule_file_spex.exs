defmodule CodeMySpecSpex.Story711.Criterion6244Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6244 — Re-install preserves a user-modified rule file.

  When the project's `.code_my_spec/rules/` already contains a
  user-modified rule file (same filename as a framework default, but
  different content) and the agent calls `install_rules` again, the tool
  leaves the user-modified file untouched while still copying other
  framework rules that were absent.

  Surface: `InstallRules` MCP tool. Assertions read rule file bytes back
  from `context.scope.cwd`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallRules

  setup :register_log_in_setup_account
  setup :setup_active_project

  @user_marker "# USER-MODIFIED — do not overwrite\n"

  spex "install_rules copies framework rule files from priv/rules/ into .code_my_spec/rules/" do
    scenario "Re-install preserves a user-modified rule file" do
      given_ "elixir.md in the project's rules dir holds user-written content distinct from the framework default",
             context do
        rules_dir = Path.join([context.scope.cwd, ".code_my_spec", "rules"])
        File.mkdir_p!(rules_dir)

        user_rule_path = Path.join(rules_dir, "elixir.md")
        File.write!(user_rule_path, @user_marker)

        # Pick a framework rule we expect to land on this re-install. Any
        # .md file in priv/rules other than elixir.md will do.
        source_dir = Application.app_dir(:code_my_spec, "priv/rules")

        other_framework_rule =
          source_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(&(&1 == "elixir.md"))
          |> List.first()

        assert other_framework_rule,
               "expected priv/rules to contain at least one .md file other than elixir.md"

        {:ok,
         Map.merge(context, %{
           rules_dir: rules_dir,
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
        contents = File.read!(context.user_rule_path)

        assert contents == @user_marker,
               "expected user-modified elixir.md to be preserved, got:\n#{contents}"

        {:ok, context}
      end

      and_ "other framework rules absent before the call are now present", context do
        other_path = Path.join(context.rules_dir, context.other_framework_rule)

        assert File.exists?(other_path),
               "expected framework rule `#{context.other_framework_rule}` at `#{other_path}` after install"

        {:ok, context}
      end
    end
  end
end
