defmodule CodeMySpec.BddRulesTest do
  use CodeMySpecTest.DataCase

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Repo

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  describe "delete_rule/2 cascade" do
    test "removes scenarios linked to the rule, leaving standalone criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)

      scenario = criterion_fixture(scope, story, %{rule_id: rule.id})
      standalone = criterion_fixture(scope, story)

      assert {:ok, deleted} = BddRules.delete_rule(scope, rule)
      assert deleted.id == rule.id

      # Regression: the linked scenario must be deleted, not orphaned with a
      # nil rule_id (the criteria FK is on_delete: :nilify_all). Orphans kept
      # inflating the story's acceptance-criteria count and survived a delete
      # that claimed to cascade.
      refute Repo.get(Criterion, scenario.id)
      # A criterion never linked to the rule is untouched.
      assert Repo.get(Criterion, standalone.id)
      refute Repo.get(Rule, rule.id)
    end

    test "deletes a rule with no linked scenarios" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)

      assert {:ok, _deleted} = BddRules.delete_rule(scope, rule)
      refute Repo.get(Rule, rule.id)
    end

    test "rejects a rule from another account without touching its scenarios" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)
      scenario = criterion_fixture(scope, story, %{rule_id: rule.id})

      assert {:error, :cross_account} = BddRules.delete_rule(other, rule)
      assert Repo.get(Criterion, scenario.id)
      assert Repo.get(Rule, rule.id)
    end
  end

  defp insert_rule(scope, story) do
    %Rule{}
    |> Rule.changeset(%{
      account_id: scope.active_account_id,
      project_id: scope.active_project_id,
      story_id: story.id,
      statement: "A rule that groups one or more scenarios"
    })
    |> Repo.insert!()
  end
end
