defmodule CodeMySpec.Requirements.StorySubmissionGraphTest do
  @moduledoc "Story submissions fan into shared readiness without an aggregate fix task."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements.IssuesChecker
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.StoryIssueGraph
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

    test "the static story chain retains triage, readiness, QA and promotion" do
      template = RequirementDefinitionData.story_graph()
      by_name = Map.new(template, &{&1.name, &1})
      id_of = fn name -> by_name[name].id end

      refute Map.has_key?(by_name, "story_issues_resolved")
      assert id_of.("story_issues_triaged") in by_name["ready_for_qa"].prerequisites

      refute Map.has_key?(by_name, "problems_resolved"),
             "28d72f8a: analyzer findings are the promote gate's job, not a QA prerequisite"

      assert by_name["qa_complete"].prerequisites ==
               [id_of.("ready_for_qa")],
             "QA waits for certification after issues are cleared"

      assert by_name["story_promoted"].prerequisites == [id_of.("qa_complete")],
             "story 1003: promotion follows QA, not the other way round"

      assert by_name["deploy"].prerequisites == [id_of.("story_promoted")],
             "deploy has to stay downstream of promotion, or a story could " <>
               "reach UAT before its code ever landed on main"
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

  describe "individual submission branches" do
    setup do
      scope = full_scope_fixture()
      {:ok, story} = Stories.create_story(scope, story_attrs("Story under test"))
      %{scope: scope, story: story}
    end

    test "each accepted blocking issue fans from triage into shared readiness", ctx do
      first = accept!(ctx.scope, ctx.story.id, "Broken save", :high)
      second = accept!(ctx.scope, ctx.story.id, "Broken login", :critical)
      config = %{fix_issues_min_severity: :medium}
      graph_ctx = %{story_issues: [first, second]}
      nodes = StoryIssueGraph.nodes(ctx.story, graph_ctx, config)
      assert MapSet.new(nodes, & &1.entity_id) == MapSet.new([first.id, second.id])
      assert Enum.all?(nodes, &(&1.name == "submitted" and not &1.satisfied))
      edges = StoryIssueGraph.edges(ctx.story, graph_ctx, config)

      for issue <- [first, second] do
        assert %{
                 from: {"story", ctx.story.id, "story_issues_triaged"},
                 to: {"issue", issue.id, "submitted"}
               } in edges

        assert %{
                 from: {"issue", issue.id, "submitted"},
                 to: {"story", ctx.story.id, "ready_for_qa"}
               } in edges
      end
    end

    test "other stories, explicit bags, low severity and untriaged issues do not become submissions",
         ctx do
      {:ok, other} = Stories.create_story(ctx.scope, story_attrs("Other story"))
      other_issue = accept!(ctx.scope, other.id, "Other", :high)
      low = accept!(ctx.scope, ctx.story.id, "Cosmetic", :low)
      pending = accept!(ctx.scope, ctx.story.id, "Pending triage", :high)
      pending = %{pending | status: :incoming}
      bag = accept!(ctx.scope, ctx.story.id, "Explicit bag", :high)
      bag = %{bag | assigned_working_copy_id: Ecto.UUID.generate()}
      graph_ctx = %{story_issues: [other_issue, low, pending, bag]}

      assert StoryIssueGraph.nodes(ctx.story, graph_ctx, %{fix_issues_min_severity: :medium}) ==
               []

      assert StoryIssueGraph.edges(ctx.story, graph_ctx, %{fix_issues_min_severity: :medium}) ==
               []
    end

    test "the graph reports recorded submission identity and clears on rework", ctx do
      issue = accept!(ctx.scope, ctx.story.id, "Fix", :high)
      ref = Ecto.UUID.generate()
      submitted = %{issue | story_submission_ref: ref, story_submission_revision: "abc"}
      config = %{fix_issues_min_severity: :medium}
      assert [node] = StoryIssueGraph.nodes(ctx.story, %{story_issues: [submitted]}, config)
      assert node.satisfied
      assert node.details["submission_ref"] == ref
      assert [pending] = StoryIssueGraph.nodes(ctx.story, %{story_issues: [issue]}, config)
      refute pending.satisfied
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

    test "triaged? follows the threshold for an issue with no story", %{scope: scope} do
      {:ok, _} =
        Issues.create_issue(scope, %{
          title: "Untriaged medium",
          description: "…",
          severity: :medium,
          story_id: nil
        })

      assert {false, _} = IssuesChecker.triaged?(scope, nil)

      {:ok, _} = Configurations.update(scope, %{fix_issues_min_severity: :high})

      assert {true, _} = IssuesChecker.triaged?(scope, nil)
    end

    test "triaged? counts an issue on a story at any severity", %{scope: scope, story: story} do
      # 255f1dcd: an untriaged issue holds its story's QA, so triage has to
      # reach it whatever the threshold says.
      {:ok, _} =
        Issues.create_issue(scope, %{
          title: "Untriaged low",
          description: "…",
          severity: :low,
          story_id: story.id
        })

      assert {false, _} = IssuesChecker.triaged?(scope, nil)
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
      assert Issues.story_submission_snapshot(scope, story.id) == %{}

      assert 1 == Issues.attribute_to_story(scope, [issue.id], story.id)

      {:ok, _} = Issues.accept_issue(scope, Issues.get_issue!(scope, issue.id))
      assert Issues.story_submission_snapshot(scope, story.id) == %{issue.id => nil}
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
        Issues.create_issue(scope, %{
          app_issue("Filed against another story")
          | story_id: other.id
        })

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
