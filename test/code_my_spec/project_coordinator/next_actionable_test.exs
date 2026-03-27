defmodule CodeMySpec.ProjectCoordinator.NextActionableTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsRepository

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # ============================================================================
  # Graph-based next actionable
  # ============================================================================

  describe "Requirements.next_actionable_project/1" do
    test "returns unsatisfied requirement with no deps", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      [req] = Requirements.next_actionable_project(scope)
      assert req.name == "technical_strategy"
      assert req.satisfied_by == CodeMySpec.AgentTasks.TechnicalStrategy
    end

    test "skips satisfied requirements", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      create_project_requirement(scope, "architecture_designed", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign
      )

      reqs = Requirements.next_actionable_project(scope)
      assert length(reqs) == 1
      assert hd(reqs).name == "architecture_designed"
    end

    test "skips requirements without satisfied_by", %{scope: scope} do
      create_project_requirement(scope, "all_stories_complete", :dependencies, false)

      assert [] == Requirements.next_actionable_project(scope)
    end

    test "respects depends_on edges — blocked requirement not returned", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      # architecture_designed depends on technical_strategy
      create_project_requirement(scope, "architecture_designed", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign,
        depends_on: [
          %{
            "entity_type" => "project",
            "entity_id" => scope.active_project_id,
            "requirement_name" => "technical_strategy"
          }
        ]
      )

      reqs = Requirements.next_actionable_project(scope)
      # Only technical_strategy is actionable (architecture_designed is blocked)
      assert length(reqs) == 1
      assert hd(reqs).name == "technical_strategy"
    end

    test "unblocks requirement when dependency is satisfied", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      create_project_requirement(scope, "architecture_designed", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign,
        depends_on: [
          %{
            "entity_type" => "project",
            "entity_id" => scope.active_project_id,
            "requirement_name" => "technical_strategy"
          }
        ]
      )

      reqs = Requirements.next_actionable_project(scope)
      assert length(reqs) == 1
      assert hd(reqs).name == "architecture_designed"
    end

    test "returns empty when all satisfied", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, true,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      assert [] == Requirements.next_actionable_project(scope)
    end

    test "cross-entity edges: story blocked by unsatisfied project requirement", %{scope: scope} do
      create_project_requirement(scope, "architecture_designed", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign
      )

      story = story_fixture(scope, %{priority: 1})

      create_story_requirement(scope, story, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureReview,
        depends_on: [
          %{
            "entity_type" => "project",
            "entity_id" => scope.active_project_id,
            "requirement_name" => "architecture_designed"
          }
        ]
      )

      reqs = Requirements.next_actionable_project(scope)
      # Only project requirement is actionable (story blocked by project dep)
      assert length(reqs) == 1
      assert hd(reqs).name == "architecture_designed"
    end

    test "component requirement actionable when story deps are met", %{scope: scope} do
      component = component_fixture(scope, %{name: "Blog", module_name: "Blog", type: "schema"})
      story = story_fixture(scope, %{component_id: component.id, priority: 1})

      create_story_requirement(scope, story, "component_linked", :dependencies, true)
      create_story_requirement(scope, story, "component_complete", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.DevelopComponent,
        scope: :children,
        depends_on: [
          %{
            "entity_type" => "component",
            "entity_id" => component.id,
            "requirement_name" => "tests_passing"
          }
        ]
      )

      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :tests,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentTest,
        depends_on: [
          %{
            "entity_type" => "component",
            "entity_id" => component.id,
            "requirement_name" => "spec_file"
          }
        ]
      })

      reqs = Requirements.next_actionable_project(scope)
      names = Enum.map(reqs, & &1.name)
      # spec_file is actionable (no deps), tests_passing is blocked by spec_file
      assert "spec_file" in names
      refute "tests_passing" in names
    end
  end

  # ============================================================================
  # Priority ordering
  # ============================================================================

  describe "priority ordering" do
    test "project requirements come before story requirements", %{scope: scope} do
      create_project_requirement(scope, "technical_strategy", :specification, false,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy
      )

      story = story_fixture(scope, %{priority: 1})

      create_story_requirement(scope, story, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureReview
      )

      reqs = Requirements.next_actionable_project(scope)
      assert length(reqs) == 2
      assert hd(reqs).name == "technical_strategy"
    end

    test "story requirements ordered by story priority", %{scope: scope} do
      story_low = story_fixture(scope, %{priority: 5, title: "Low priority"})
      story_high = story_fixture(scope, %{priority: 1, title: "High priority"})

      create_story_requirement(scope, story_low, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureReview
      )

      create_story_requirement(scope, story_high, "component_linked", :dependencies, false,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureReview
      )

      reqs = Requirements.next_actionable_project(scope)
      assert length(reqs) == 2
      # Higher priority story (lower number) comes first
      assert Enum.at(reqs, 0).story_id == story_high.id
      assert Enum.at(reqs, 1).story_id == story_low.id
    end

    test "component requirements sorted by owning story priority", %{scope: scope} do
      comp_low = component_fixture(scope, %{name: "Low", module_name: "Low", type: "schema"})
      comp_high = component_fixture(scope, %{name: "High", module_name: "High", type: "schema"})

      _story_low = story_fixture(scope, %{priority: 5, component_id: comp_low.id})
      _story_high = story_fixture(scope, %{priority: 1, component_id: comp_high.id})

      requirement_fixture(scope, comp_low, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      requirement_fixture(scope, comp_high, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec
      })

      reqs = Requirements.next_actionable_project(scope)
      assert length(reqs) == 2
      # Higher priority story's component comes first
      assert Enum.at(reqs, 0).component_id == comp_high.id
      assert Enum.at(reqs, 1).component_id == comp_low.id
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
      |> maybe_put_opt(opts, :depends_on)

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
      |> maybe_put_opt(opts, :depends_on)

    {:ok, _} = RequirementsRepository.create_story_requirement(scope, story, attrs)
  end

  defp maybe_put_opt(attrs, opts, key) do
    case Keyword.get(opts, key) do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
  end
end
