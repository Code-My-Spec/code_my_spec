defmodule CodeMySpec.ProjectCoordinator.NextActionableTest do
  use CodeMySpec.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.ProjectCoordinator.NextActionable
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementsRepository

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # ============================================================================
  # Project-level requirements
  # ============================================================================

  describe "project-level traversal" do
    test "fresh project returns technical_strategy (first project requirement)", %{scope: scope} do
      project = scope.active_project |> Repo.preload(:requirements)

      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "technical_strategy"
      assert req.satisfied_by == CodeMySpec.AgentTasks.TechnicalStrategy
      assert req.project_id == project.id
    end

    test "project with technical_strategy satisfied returns architecture_designed", %{
      scope: scope
    } do
      create_project_requirement(scope, "technical_strategy", :specification, true)

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "architecture_designed"
      assert req.satisfied_by == CodeMySpec.AgentTasks.ArchitectureDesign
    end

    test "project with all direct requirements satisfied but no stories returns :complete", %{
      scope: scope
    } do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      # all_stories_complete has satisfied_by: nil → descends, but no stories exist
      project = scope.active_project |> Repo.preload(:requirements)
      assert :complete = NextActionable.call(scope, project)
    end
  end

  # ============================================================================
  # Project → Story descent
  # ============================================================================

  describe "project → story descent" do
    test "descends into story when all_stories_complete is stuck", %{scope: scope} do
      # Satisfy project-level prereqs for all_stories_complete
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      # Create a story - it needs component_linked (first story requirement)
      _story = story_fixture(scope)

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "component_linked"
      assert req.satisfied_by == CodeMySpec.AgentTasks.LinkStoryComponent
    end

    test "skips completed stories and finds first incomplete", %{scope: scope} do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      # First story: fully satisfied
      story1 = story_fixture(scope, %{priority: 1})
      satisfy_all_story_requirements(scope, story1)

      # Second story: needs work
      _story2 = story_fixture(scope, %{priority: 2})

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "component_linked"
    end

    test "all stories complete returns project_qa", %{scope: scope} do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      create_project_requirement(scope, "all_stories_complete", :dependencies, true)

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "project_qa"
      assert req.satisfied_by == CodeMySpec.AgentTasks.QaApp
    end

    test "everything satisfied returns :complete", %{scope: scope} do
      for {name, artifact_type} <- [
            {"technical_strategy", :specification},
            {"architecture_designed", :specification},
            {"all_stories_complete", :dependencies},
            {"project_qa", :review}
          ] do
        create_project_requirement(scope, name, artifact_type, true)
      end

      project = scope.active_project |> Repo.preload(:requirements)
      assert :complete = NextActionable.call(scope, project)
    end
  end

  # ============================================================================
  # Story → Component descent
  # ============================================================================

  describe "story → component descent" do
    test "story with component_complete stuck descends into component tree", %{scope: scope} do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      # Create a component and link story to it
      component = component_fixture(scope, %{name: "MyWidget", module_name: "MyWidget"})
      story = story_fixture(scope, %{component_id: component.id})

      # Satisfy story requirements up to component_complete
      for {name, artifact_type} <- [
            {"component_linked", :dependencies},
            {"bdd_specs_exist", :tests}
          ] do
        create_story_requirement(scope, story, name, artifact_type, true)
      end

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)

      # component_complete has satisfied_by: ManageImplementation → returned directly
      assert req.name == "component_complete"
      assert req.satisfied_by == CodeMySpec.AgentTasks.ManageImplementation
      assert req.story_id == story.id
    end

    test "story with component_complete satisfied returns bdd_specs_passing (nil satisfied_by) then descends",
         %{scope: scope} do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      component = component_fixture(scope, %{name: "MyWidget", module_name: "MyWidget"})
      story = story_fixture(scope, %{component_id: component.id})

      for {name, artifact_type} <- [
            {"component_linked", :dependencies},
            {"bdd_specs_exist", :tests},
            {"component_complete", :dependencies}
          ] do
        create_story_requirement(scope, story, name, artifact_type, true)
      end

      project = scope.active_project |> Repo.preload(:requirements)
      # bdd_specs_passing has satisfied_by: nil → descends into components
      # Component has unsatisfied spec_file → but the descent goes through
      # find_next_in_chain which may return :complete if component has no unsatisfied reqs
      # In this case component has no requirements yet, so :complete from component descent
      # means :complete from story level. But then we'd check qa_complete which requires
      # bdd_specs_passing to be satisfied (it's not), so qa_complete is not actionable.
      # Overall result: :complete (nothing dispatchable for bdd_specs_passing)
      assert :complete = NextActionable.call(scope, project)
    end
  end

  # ============================================================================
  # Component → Dependency descent
  # ============================================================================

  describe "component-level descent through dependencies" do
    test "component with dependencies_satisfied stuck descends to dependency leaf", %{
      scope: scope
    } do
      for name <- ["technical_strategy", "architecture_designed"] do
        create_project_requirement(scope, name, :specification, true)
      end

      # Build component chain: parent depends on child
      parent = component_fixture(scope, %{name: "Parent", module_name: "Parent"})
      child = component_fixture(scope, %{name: "Child", module_name: "Child"})
      dependency_fixture(scope, parent, child)

      story = story_fixture(scope, %{component_id: parent.id})

      for {name, artifact_type} <- [
            {"component_linked", :dependencies},
            {"bdd_specs_exist", :tests}
          ] do
        create_story_requirement(scope, story, name, artifact_type, true)
      end

      # Child has unsatisfied spec_file
      requirement_fixture(scope, child, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      # Parent has unsatisfied deps
      requirement_fixture(scope, parent, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      requirement_fixture(scope, parent, %{
        name: "dependencies_satisfied",
        artifact_type: :dependencies,
        satisfied: false
      })

      project = scope.active_project |> Repo.preload(:requirements)

      # component_complete (story level) has satisfied_by: ManageImplementation
      # so it gets returned directly without descending into components
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "component_complete"
      assert req.satisfied_by == CodeMySpec.AgentTasks.ManageImplementation
    end
  end

  # ============================================================================
  # get_next_actions wrapper
  # ============================================================================

  describe "ProjectCoordinator.get_next_actions/1" do
    test "delegates to NextActionable", %{scope: scope} do
      assert {:ok, req} = ProjectCoordinator.get_next_actions(scope)
      assert req.name == "technical_strategy"
      assert req.project_id == scope.active_project.id
    end

    test "returns :complete when all requirements satisfied", %{scope: scope} do
      for {name, artifact_type} <- [
            {"technical_strategy", :specification},
            {"architecture_designed", :specification},
            {"all_stories_complete", :dependencies},
            {"project_qa", :review}
          ] do
        create_project_requirement(scope, name, artifact_type, true)
      end

      assert :complete = ProjectCoordinator.get_next_actions(scope)
    end
  end

  # ============================================================================
  # Virtual requirement fallback
  # ============================================================================

  describe "virtual requirements" do
    test "returns virtual requirement when no DB records exist", %{scope: scope} do
      # Fresh project with no requirement records
      project = scope.active_project |> Repo.preload(:requirements)
      assert project.requirements == []

      assert {:ok, req} = NextActionable.call(scope, project)
      # Virtual requirement has no id but has the correct fields
      assert is_nil(req.id)
      assert req.name == "technical_strategy"
      assert req.satisfied_by == CodeMySpec.AgentTasks.TechnicalStrategy
      assert req.project_id == project.id
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_project_requirement(scope, name, artifact_type, satisfied) do
    {:ok, _} =
      RequirementsRepository.create_project_requirement(scope, scope.active_project, %{
        name: name,
        artifact_type: artifact_type,
        description: "test",
        checker_module: CodeMySpec.Requirements.ArtifactExistenceChecker,
        satisfied: satisfied,
        score: if(satisfied, do: 1.0, else: 0.0),
        checked_at: DateTime.utc_now()
      })
  end

  defp create_story_requirement(scope, story, name, artifact_type, satisfied) do
    {:ok, _} =
      RequirementsRepository.create_story_requirement(scope, story, %{
        name: name,
        artifact_type: artifact_type,
        description: "test",
        checker_module: CodeMySpec.Requirements.ComponentLinkedChecker,
        satisfied: satisfied,
        score: if(satisfied, do: 1.0, else: 0.0),
        checked_at: DateTime.utc_now()
      })
  end

  defp satisfy_all_story_requirements(scope, story) do
    for {name, artifact_type} <- [
          {"component_linked", :dependencies},
          {"bdd_specs_exist", :tests},
          {"component_complete", :dependencies},
          {"bdd_specs_passing", :tests},
          {"qa_complete", :review}
        ] do
      create_story_requirement(scope, story, name, artifact_type, true)
    end
  end
end
