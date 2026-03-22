defmodule CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummaryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummary
  alias Anubis.Server.Frame

  describe "ArchitectureHealthSummary tool" do
    setup do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      %{scope: scope}
    end

    test "returns excellent health for empty architecture", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ArchitectureHealthSummary.execute(%{}, frame)
      assert response.type == :tool

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)

      health = parsed["architecture_health"]
      assert health["overall_score"]["health_level"] == "excellent"
      assert health["story_coverage"]["total_components"] == 0
    end

    test "analyzes story coverage correctly distinguishing entry/dependency/orphaned", %{
      scope: scope
    } do
      entry_comp = component_fixture(scope, %{name: "EntryComponent"})
      dependency_comp = component_fixture(scope, %{name: "DependencyComponent"})
      _orphaned_comp = component_fixture(scope, %{name: "OrphanedComponent"})

      story_fixture(scope, %{component_id: entry_comp.id})
      dependency_fixture(scope, entry_comp, dependency_comp)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ArchitectureHealthSummary.execute(%{}, frame)

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)

      coverage = parsed["architecture_health"]["story_coverage"]
      assert coverage["total_components"] == 3
      assert coverage["entry_components"] == 1
      assert coverage["dependency_components"] == 1
      assert coverage["orphaned_components"] == 1
      # 1 entry / (1 entry + 1 orphaned) = 50%
      assert coverage["story_coverage_percentage"] == 50.0
      assert coverage["orphaned_percentage"] == 33.3
    end

    test "analyzes context distribution with raw story counts", %{scope: scope} do
      entry_comp = component_fixture(scope, %{name: "EntryComp"})
      dependency_comp = component_fixture(scope, %{name: "DependencyComp"})
      single_story_comp = component_fixture(scope, %{name: "SingleStory"})
      multi_story_comp = component_fixture(scope, %{name: "MultiStory"})
      _orphaned_comp = component_fixture(scope, %{name: "OrphanedComp"})

      story_fixture(scope, %{component_id: entry_comp.id})
      dependency_fixture(scope, entry_comp, dependency_comp)

      story_fixture(scope, %{component_id: single_story_comp.id})
      story_fixture(scope, %{component_id: multi_story_comp.id, title: "Story 1"})
      story_fixture(scope, %{component_id: multi_story_comp.id, title: "Story 2"})
      story_fixture(scope, %{component_id: multi_story_comp.id, title: "Story 3"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ArchitectureHealthSummary.execute(%{}, frame)

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)

      distribution = parsed["architecture_health"]["context_distribution"]
      story_dist = distribution["story_distribution"]

      # dependency + orphaned
      assert story_dist["0"] == 2
      # entry + single_story
      assert story_dist["1"] == 2
      # multi_story
      assert story_dist["3"] == 1
      assert distribution["orphaned_components"] == 1
      assert distribution["dependency_components"] == 1
    end

    test "detects high fan-out components", %{scope: scope} do
      root = component_fixture(scope, %{name: "HighFanOut"})
      story_fixture(scope, %{component_id: root.id})

      for i <- 1..6 do
        dep = component_fixture(scope, %{name: "Dep#{i}"})
        dependency_fixture(scope, root, dep)
      end

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ArchitectureHealthSummary.execute(%{}, frame)

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)

      dep_issues = parsed["architecture_health"]["dependency_issues"]
      assert length(dep_issues["high_fan_out_components"]) == 1

      high_fan_out = hd(dep_issues["high_fan_out_components"])
      assert high_fan_out["name"] == "HighFanOut"
      assert high_fan_out["dependency_count"] == 6
    end

    test "handles scope validation errors" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = ArchitectureHealthSummary.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == true
    end
  end
end
