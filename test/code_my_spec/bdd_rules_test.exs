defmodule CodeMySpec.BddRulesTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Repo

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  describe "delete_rule/2 cascade" do
    test "retires scenarios linked to the rule, leaving standalone criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)

      scenario = criterion_fixture(scope, story, %{rule_id: rule.id})
      standalone = criterion_fixture(scope, story)

      assert {:ok, deleted} = BddRules.delete_rule(scope, rule)
      assert deleted.id == rule.id

      # The linked scenario must leave the story, not linger active with a nil
      # rule_id — orphans inflated the story's criteria count. It is retired
      # rather than deleted, so its number is never reused.
      assert Repo.get(Criterion, scenario.id).retired_at
      # A criterion never linked to the rule is untouched.
      refute Repo.get(Criterion, standalone.id).retired_at
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

    # 146c01a6: `delete_criterion/2`'s tool-level guard already refuses a
    # verified criterion one at a time. The cascade had no equivalent, so
    # "PM-side cleanup of a bogus rule" could hard-delete verified work with
    # real spec files still on disk in one call — Broken Oaths measured: 23
    # verified criteria deleted, recreated under new ids with spec_path nil,
    # 20 real passing spec files on disk left claimed by nothing.
    test "refuses to delete a rule with a verified scenario" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)
      verified = verified_criterion_fixture(scope, story, %{rule_id: rule.id})

      assert {:error, {:criteria_verified_or_specced, descriptions}} =
               BddRules.delete_rule(scope, rule)

      assert descriptions == [verified.description]
      assert Repo.get(Criterion, verified.id), "the criterion must survive the refusal"
      assert Repo.get(Rule, rule.id), "the rule must survive alongside it"
    end

    # The other half of what the cascade was destroying: a criterion can hold
    # a real spec file without being marked verified (verification and
    # authoring a spec are separate acts), and orphaning the file is the
    # actual, measured harm — the verified check alone would have missed
    # this shape.
    test "refuses to delete a rule with a criterion that already has a spec file" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)

      specced =
        criterion_fixture(scope, story, %{
          rule_id: rule.id,
          spec_path: "test/spex/1_a_story/criterion_1_spex.exs"
        })

      assert {:error, {:criteria_verified_or_specced, descriptions}} =
               BddRules.delete_rule(scope, rule)

      assert descriptions == [specced.description]
      assert Repo.get(Criterion, specced.id)
    end

    test "still deletes a rule whose scenarios are neither verified nor specced" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      rule = insert_rule(scope, story)
      scenario = criterion_fixture(scope, story, %{rule_id: rule.id})

      assert {:ok, _deleted} = BddRules.delete_rule(scope, rule)
      assert Repo.get(Criterion, scenario.id).retired_at
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
