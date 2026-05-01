defmodule CodeMySpec.RulesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Rules

  @moduletag :tmp_dir

  defp write_rule_file!(tmp_dir, filename, opts) do
    component_type = Keyword.get(opts, :component_type, "*")
    session_type = Keyword.get(opts, :session_type, "*")
    content = Keyword.get(opts, :content, "Rule content for #{filename}")

    rules_dir = Path.join(tmp_dir, ".code_my_spec/rules")
    File.mkdir_p!(rules_dir)

    file_content = """
    ---
    component_type: #{component_type}
    session_type: #{session_type}
    ---
    #{content}
    """

    File.write!(Path.join(rules_dir, filename), file_content)
  end

  describe "find_matching_rules/3 with working_dir" do
    test "reads rules from the project's .code_my_spec/rules/ directory", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "test_rule.md",
        component_type: "context",
        session_type: "design",
        content: "Context design rule"
      )

      rules = Rules.find_matching_rules("context", "design", Environment.new(:local, tmp_dir))

      assert length(rules) == 1
      assert hd(rules).name == "test_rule"
      assert hd(rules).content =~ "Context design rule"
    end

    test "filters by component_type", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "context_rule.md",
        component_type: "context",
        session_type: "design"
      )

      write_rule_file!(tmp_dir, "schema_rule.md",
        component_type: "schema",
        session_type: "design"
      )

      rules = Rules.find_matching_rules("context", "design", Environment.new(:local, tmp_dir))
      assert length(rules) == 1
      assert hd(rules).name == "context_rule"
    end

    test "filters by session_type", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "design_rule.md",
        component_type: "context",
        session_type: "design"
      )

      write_rule_file!(tmp_dir, "test_rule.md",
        component_type: "context",
        session_type: "test"
      )

      rules = Rules.find_matching_rules("context", "test", Environment.new(:local, tmp_dir))
      assert length(rules) == 1
      assert hd(rules).name == "test_rule"
    end

    test "wildcard component_type matches all", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "global_rule.md",
        component_type: "*",
        session_type: "design"
      )

      rules = Rules.find_matching_rules("anything", "design", Environment.new(:local, tmp_dir))
      assert length(rules) == 1
    end

    test "wildcard session_type matches all", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "universal_rule.md",
        component_type: "context",
        session_type: "*"
      )

      rules = Rules.find_matching_rules("context", "code", Environment.new(:local, tmp_dir))
      assert length(rules) == 1
    end

    test "returns empty list when rules directory does not exist", %{tmp_dir: tmp_dir} do
      rules = Rules.find_matching_rules("context", "design", Environment.new(:local, tmp_dir))
      assert rules == []
    end

    test "returns empty list when no rules match", %{tmp_dir: tmp_dir} do
      write_rule_file!(tmp_dir, "schema_rule.md",
        component_type: "schema",
        session_type: "test"
      )

      rules = Rules.find_matching_rules("context", "design", Environment.new(:local, tmp_dir))
      assert rules == []
    end
  end

  describe "find_matching_rules/2 without working_dir" do
    test "falls back to relative path (process cwd)" do
      # Without working_dir, uses relative .code_my_spec/rules/
      # This will return empty since process cwd likely doesn't have rules
      rules = Rules.find_matching_rules("context", "design")
      assert is_list(rules)
    end
  end
end
