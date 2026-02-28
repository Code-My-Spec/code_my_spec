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
    test "returns first unsatisfied project requirement", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "technical_strategy"
      assert req.satisfied_by == CodeMySpec.AgentTasks.TechnicalStrategy
      assert req.project_id == project.id
    end

    test "skips satisfied requirements and returns next unsatisfied", %{
      scope: scope
    } do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign
      )

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "architecture_designed"
      assert req.satisfied_by == CodeMySpec.AgentTasks.ArchitectureDesign
    end

    test "all_stories_complete with no stories returns error", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # all_stories_complete has scope: :dependencies → descends into stories,
      # finds none → error (unsatisfied but nothing to descend into)
      project = scope.active_project |> Repo.preload(:requirements)
      assert {:error, msg} = NextActionable.call(scope, project)
      assert msg =~ "all_stories_complete"
      assert msg =~ "dependencies"
    end
  end

  # ============================================================================
  # Project → Story descent
  # ============================================================================

  describe "project → story descent" do
    test "descends into story when all_stories_complete is stuck", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # Create a story with its first requirement unsatisfied
      story = story_fixture(scope)
      create_story_requirement(scope, story, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.LinkStoryComponent
      )

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "component_linked"
      assert req.satisfied_by == CodeMySpec.AgentTasks.LinkStoryComponent
    end

    test "skips completed stories and finds first incomplete", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # First story: fully satisfied
      story1 = story_fixture(scope, %{priority: 1})
      satisfy_all_story_requirements(scope, story1)

      # Second story: needs work
      story2 = story_fixture(scope, %{priority: 2})
      create_story_requirement(scope, story2, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.LinkStoryComponent
      )

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "component_linked"
    end

    test "all stories complete returns project_qa", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, true)
      create_project_requirement(scope, "project_qa", :review, false,
        satisfied_by: CodeMySpec.AgentTasks.QaApp
      )

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
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # Create a component and link story to it
      component = component_fixture(scope, %{name: "MyWidget", module_name: "MyWidget"})
      story = story_fixture(scope, %{component_id: component.id})

      # Satisfy story requirements up to component_complete
      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        scope: :dependencies
      )

      project = scope.active_project |> Repo.preload(:requirements)

      # component_complete has scope: :dependencies → descends into component chain.
      # Component has no requirements in DB → find_next_in_chain returns :complete →
      # error (unsatisfied but dependencies all complete)
      assert {:error, msg} = NextActionable.call(scope, project)
      assert msg =~ "component_complete"
    end

    test "story with component_complete satisfied returns bdd_specs_passing", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      component = component_fixture(scope, %{name: "MyWidget", module_name: "MyWidget"})
      story = story_fixture(scope, %{component_id: component.id})

      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_passing", :tests, false)

      project = scope.active_project |> Repo.preload(:requirements)
      # bdd_specs_passing has scope: :local → returned immediately
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "bdd_specs_passing"
    end
  end

  # ============================================================================
  # Component → Dependency descent
  # ============================================================================

  describe "component-level descent through dependencies" do
    test "component with dependencies_satisfied stuck descends to dependency leaf", %{
      scope: scope
    } do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # Build component chain: parent depends on child
      parent = component_fixture(scope, %{name: "Parent", module_name: "Parent"})
      child = component_fixture(scope, %{name: "Child", module_name: "Child"})
      dependency_fixture(scope, parent, child)

      story = story_fixture(scope, %{component_id: parent.id})
      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        scope: :dependencies
      )

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

      # component_complete has scope: :dependencies → descends into dependency chain →
      # find_next_in_chain finds Child (leaf) is ready → Child's spec_file is first stuck
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "spec_file"
      assert req.component_id == child.id
    end
  end

  # ============================================================================
  # Scope-based dispatch
  # ============================================================================

  describe "scope-based dispatch" do
    test ":local scope with satisfied_by: nil returns requirement (not :complete)", %{
      scope: scope
    } do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      component = component_fixture(scope, %{name: "TestComp", module_name: "TestComp"})
      story = story_fixture(scope, %{component_id: component.id})

      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_passing", :tests, false)

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)
      assert req.name == "bdd_specs_passing"
      assert req.scope == :local
    end

    test ":children scope descends into child components", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # Create a context (parent) with a child component
      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})

      child =
        component_fixture(scope, %{
          name: "Post",
          module_name: "Blog.Post",
          type: "schema",
          parent_component_id: context.id
        })

      story = story_fixture(scope, %{component_id: context.id})

      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        scope: :dependencies
      )

      # Context has spec_file + spec_valid satisfied, children_designs is stuck (scope: :children)
      requirement_fixture(scope, context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

      requirement_fixture(scope, context, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

      # children_designs is unsatisfied — scope: :children triggers descent into child components
      requirement_fixture(scope, context, %{
        name: "children_designs",
        artifact_type: :hierarchy,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs,
        scope: :children
      })

      # Child has unsatisfied spec_file
      requirement_fixture(scope, child, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)

      # component_complete (scope: :dependencies) descends → find_next_in_chain →
      # context is ready (has unsatisfied children_designs, deps vacuously met) →
      # children_designs (scope: :children) → validates children have work →
      # returns the PARENT requirement (execution layer orchestrates children)
      assert req.name == "children_designs"
      assert req.component_id == context.id
      assert req.scope == :children
    end

    test ":children scope returns error when no children have work", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      context = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "context"})
      story = story_fixture(scope, %{component_id: context.id})

      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        scope: :dependencies
      )

      # Context has children_designs stuck but no child components exist
      requirement_fixture(scope, context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

      requirement_fixture(scope, context, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

      requirement_fixture(scope, context, %{
        name: "children_designs",
        artifact_type: :hierarchy,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs,
        scope: :children
      })

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:error, msg} = NextActionable.call(scope, project)
      assert msg =~ "children_designs"
      assert msg =~ "children"
    end

    test ":dependencies scope descends through component dependency chain", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true)
      create_project_requirement(scope, "architecture_designed", :specification, true)
      create_project_requirement(scope, "all_stories_complete", :dependencies, false,
        scope: :dependencies
      )

      # Build dependency chain: widget depends on helper
      widget = component_fixture(scope, %{name: "Widget", module_name: "Widget"})
      helper = component_fixture(scope, %{name: "Helper", module_name: "Helper"})
      dependency_fixture(scope, widget, helper)

      story = story_fixture(scope, %{component_id: widget.id})
      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "bdd_specs_exist", :tests, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        scope: :dependencies
      )

      # Helper has unsatisfied spec_file
      requirement_fixture(scope, helper, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      # Widget has unsatisfied deps
      requirement_fixture(scope, widget, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      requirement_fixture(scope, widget, %{
        name: "dependencies_satisfied",
        artifact_type: :dependencies,
        satisfied: false
      })

      project = scope.active_project |> Repo.preload(:requirements)
      assert {:ok, req} = NextActionable.call(scope, project)

      # component_complete (scope: :dependencies) descends → Helper is leaf →
      # Helper's spec_file is first stuck requirement
      assert req.name == "spec_file"
      assert req.component_id == helper.id
    end
  end

  # ============================================================================
  # get_next_actions wrapper
  # ============================================================================

  describe "ProjectCoordinator.get_next_actions/1" do
    test "delegates to NextActionable", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

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
  # Helpers
  # ============================================================================

  defp create_project_requirement(scope, name, artifact_type, satisfied, opts \\ []) do
    attrs =
      %{
        name: name,
        artifact_type: artifact_type,
        description: "test",
        checker_module: CodeMySpec.Requirements.ArtifactExistenceChecker,
        satisfied: satisfied,
        score: if(satisfied, do: 1.0, else: 0.0),
        checked_at: DateTime.utc_now()
      }
      |> maybe_put_opt(opts, :scope)
      |> maybe_put_opt(opts, :satisfied_by)

    {:ok, _} = RequirementsRepository.create_project_requirement(scope, scope.active_project, attrs)
  end

  defp create_story_requirement(scope, story, name, artifact_type, satisfied, opts \\ []) do
    attrs =
      %{
        name: name,
        artifact_type: artifact_type,
        description: "test",
        checker_module: CodeMySpec.Requirements.ComponentLinkedChecker,
        satisfied: satisfied,
        score: if(satisfied, do: 1.0, else: 0.0),
        checked_at: DateTime.utc_now()
      }
      |> maybe_put_opt(opts, :scope)
      |> maybe_put_opt(opts, :satisfied_by)

    {:ok, _} = RequirementsRepository.create_story_requirement(scope, story, attrs)
  end

  defp maybe_put_opt(attrs, opts, key) do
    case Keyword.get(opts, key) do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
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
