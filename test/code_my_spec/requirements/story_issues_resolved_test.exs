defmodule CodeMySpec.Requirements.StoryIssuesResolvedTest do
  @moduledoc """
  The per-story issue gate, and the template-id collision that placing it
  exposed.

  `story_issues_resolved` sits between `qa_complete` and `deploy` so a story
  does not release carrying a blocker its own QA pass raised. It reads only
  issues attributed to that story — the project queue is the end-of-cycle
  `issues_resolved` node's business, and a gate that waited on it could not
  be passed by whoever owns the story.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements.IssuesChecker
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories

  describe "story_graph template ids" do
    test "are unique — prerequisites resolve through them, last writer wins" do
      ids = Enum.map(RequirementDefinitionData.story_graph(), & &1.id)

      assert ids == Enum.uniq(ids),
             "duplicate template ids: #{inspect(ids -- Enum.uniq(ids))}"
    end

    test "every prerequisite names a def that exists in the template" do
      template = RequirementDefinitionData.story_graph()
      ids = MapSet.new(template, & &1.id)

      for def <- template, prereq <- def.prerequisites do
        assert MapSet.member?(ids, prereq),
               "#{def.name} requires id #{prereq}, which no def in story_graph carries"
      end
    end

    test "the chain runs qa_complete → story_issues_resolved → deploy" do
      template = RequirementDefinitionData.story_graph()
      by_name = Map.new(template, &{&1.name, &1})
      id_of = fn name -> by_name[name].id end

      assert by_name["story_issues_resolved"].prerequisites == [id_of.("qa_complete")]
      assert by_name["deploy"].prerequisites == [id_of.("story_issues_resolved")]
    end

    test "bdd_specs_exist gates on three_amigos_complete, not on deploy" do
      # The collision that made `deploy` id 7: it shipped as 5, which
      # `three_amigos_complete` held, so with devops on, this prerequisite
      # resolved to `deploy` and closed a cycle through the story chain.
      template = RequirementDefinitionData.story_graph()
      by_name = Map.new(template, &{&1.name, &1})
      by_id = Map.new(template, &{&1.id, &1})

      [prereq_id] = by_name["bdd_specs_exist"].prerequisites
      assert by_id[prereq_id].name == "three_amigos_complete"
    end
  end

  describe "story_resolved?/2" do
    setup do
      scope = full_scope_fixture()
      {:ok, story} = Stories.create_story(scope, story_attrs("Story under test"))
      %{scope: scope, story: story}
    end

    test "satisfied when the story carries no accepted issues", %{scope: scope, story: story} do
      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "unsatisfied while an accepted issue names the story", %{scope: scope, story: story} do
      accept!(scope, story.id, "Save button does nothing", :high)

      assert {false, details} = IssuesChecker.story_resolved?(scope, story)
      assert details.reason =~ "1 unresolved"
    end

    test "an issue on another story does not gate this one", %{scope: scope, story: story} do
      {:ok, other} = Stories.create_story(scope, story_attrs("Some other story"))
      accept!(scope, other.id, "Unrelated defect", :critical)

      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "an issue with no story does not gate — that is the project queue's job", %{
      scope: scope,
      story: story
    } do
      accept!(scope, nil, "Nobody attributed this", :critical)

      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "resolving the issue satisfies the gate", %{scope: scope, story: story} do
      issue = accept!(scope, story.id, "Save button does nothing", :high)
      assert {false, _} = IssuesChecker.story_resolved?(scope, story)

      {:ok, _} = Issues.resolve_issue(scope, issue, "Wired the handler")
      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "below the configured threshold, an issue is tracked but does not gate", %{
      scope: scope,
      story: story
    } do
      accept!(scope, story.id, "Label is slightly off", :low)

      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "raising the threshold to :high drops a medium from the gating set", %{
      scope: scope,
      story: story
    } do
      accept!(scope, story.id, "Medium defect", :medium)
      assert {false, _} = IssuesChecker.story_resolved?(scope, story)

      {:ok, _} = Configurations.update(scope, %{fix_issues_min_severity: :high})

      assert {true, _} = IssuesChecker.story_resolved?(scope, story)
    end
  end

  describe "project-level resolved?/2 honours the same threshold" do
    # It hardcoded `:medium` while `AgentTasks.FixIssues` read the config, so
    # a project set to `:high` got a requirement that could not clear and a
    # task that evaluated green the moment it was started.
    setup do
      scope = full_scope_fixture()
      {:ok, story} = Stories.create_story(scope, story_attrs("Story under test"))
      %{scope: scope, story: story}
    end

    test "a medium stops gating once the threshold is :high", %{scope: scope, story: story} do
      accept!(scope, story.id, "Medium defect", :medium)
      assert {false, _} = IssuesChecker.resolved?(scope, nil)

      {:ok, _} = Configurations.update(scope, %{fix_issues_min_severity: :high})

      assert {true, _} = IssuesChecker.resolved?(scope, nil)
    end

    test "triaged? follows the threshold too", %{scope: scope, story: story} do
      {:ok, _} =
        Issues.create_issue(scope, %{
          title: "Untriaged medium",
          description: "…",
          severity: :medium,
          story_id: story.id
        })

      assert {false, _} = IssuesChecker.triaged?(scope, nil)

      {:ok, _} = Configurations.update(scope, %{fix_issues_min_severity: :high})

      assert {true, _} = IssuesChecker.triaged?(scope, nil)
    end
  end

  describe "attribute_to_story/3" do
    # Without this, the gate is inert: every accepted issue on this project
    # reached triage with a null `story_id`, so no story could ever carry one.
    setup do
      scope = full_scope_fixture()
      {:ok, story} = Stories.create_story(scope, story_attrs("Story under test"))
      %{scope: scope, story: story}
    end

    test "attaches an unattributed app issue and gates the story", %{scope: scope, story: story} do
      {:ok, issue} = Issues.create_issue(scope, app_issue("Broken save"))
      assert {true, _} = IssuesChecker.story_resolved?(scope, story)

      assert 1 == Issues.attribute_to_story(scope, [issue.id], story.id)

      {:ok, _} = Issues.accept_issue(scope, Issues.get_issue!(scope, issue.id))
      assert {false, _} = IssuesChecker.story_resolved?(scope, story)
    end

    test "leaves framework findings to the project queue", %{scope: scope, story: story} do
      {:ok, issue} =
        Issues.create_issue(scope, %{app_issue("Hook loops") | scope: :framework})

      assert 0 == Issues.attribute_to_story(scope, [issue.id], story.id)
      assert Issues.get_issue!(scope, issue.id).story_id == nil
    end

    test "never overwrites an explicit attribution", %{scope: scope, story: story} do
      {:ok, other} = Stories.create_story(scope, story_attrs("The story it belongs to"))

      {:ok, issue} =
        Issues.create_issue(scope, %{app_issue("Filed against another story") | story_id: other.id})

      assert 0 == Issues.attribute_to_story(scope, [issue.id], story.id)
      assert Issues.get_issue!(scope, issue.id).story_id == other.id
    end

    test "ignores ids that are not uuids rather than crashing", %{scope: scope, story: story} do
      assert 0 == Issues.attribute_to_story(scope, ["not-a-uuid", ""], story.id)
    end
  end

  defp app_issue(title) do
    %{title: title, description: "…", severity: :high, scope: :app, story_id: nil}
  end

  defp story_attrs(title) do
    %{title: title, description: "As a user…", acceptance_criteria: ["AC1"]}
  end

  defp accept!(scope, story_id, title, severity) do
    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: title,
        description: "…",
        severity: severity,
        story_id: story_id
      })

    {:ok, accepted} = Issues.accept_issue(scope, issue)
    accepted
  end
end
