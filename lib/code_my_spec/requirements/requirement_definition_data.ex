defmodule CodeMySpec.Requirements.RequirementDefinitionData do
  @moduledoc """
  Central registry of all requirement definitions used across component types.
  Provides reusable requirement templates that combine checkers, session types,
  and categorization for consistent requirement checking.
  """

  alias CodeMySpec.Requirements.ContextReviewFileChecker
  alias CodeMySpec.Requirements.ContextReviewValidityChecker
  alias CodeMySpec.Requirements.DependencyChecker
  alias CodeMySpec.Requirements.DocumentValidityChecker
  alias CodeMySpec.Requirements.FileExistenceChecker
  alias CodeMySpec.Requirements.HierarchicalChecker
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.SpecTestAlignmentChecker
  alias CodeMySpec.Requirements.TestStatusChecker

  @spec spec_file() :: RequirementDefinition.t()
  def spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification file exists"
      })

    definition
  end

  @spec spec_valid() :: RequirementDefinition.t()
  def spec_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_valid",
        checker: DocumentValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification is valid"
      })

    definition
  end

  @spec implementation_file() :: RequirementDefinition.t()
  def implementation_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "implementation_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists"
      })

    definition
  end

  @spec test_file() :: RequirementDefinition.t()
  def test_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "test_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Component test file exists"
      })

    definition
  end

  @spec test_spec_alignment() :: RequirementDefinition.t()
  def test_spec_alignment do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "test_spec_alignment",
        checker: SpecTestAlignmentChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions"
      })

    definition
  end

  @spec tests_passing() :: RequirementDefinition.t()
  def tests_passing do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "tests_passing",
        checker: TestStatusChecker,
        satisfied_by: nil,
        artifact_type: :code,
        description: "Component tests are passing"
      })

    definition
  end

  @spec dependencies_satisfied() :: RequirementDefinition.t()
  def dependencies_satisfied do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "dependencies_satisfied",
        checker: DependencyChecker,
        satisfied_by: nil,
        artifact_type: :dependencies,
        description: "Component dependencies are satisfied"
      })

    definition
  end

  @spec children_designs() :: RequirementDefinition.t()
  def children_designs do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "children_designs",
        checker: HierarchicalChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs,
        artifact_type: :hierarchy,
        description: "Child component designs are complete"
      })

    definition
  end

  @spec children_implementations() :: RequirementDefinition.t()
  def children_implementations do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "children_implementations",
        checker: HierarchicalChecker,
        satisfied_by: nil,
        artifact_type: :hierarchy,
        description: "Child component implementations are complete"
      })

    definition
  end

  @spec review_file() :: RequirementDefinition.t()
  def review_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "review_file",
        checker: ContextReviewFileChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Context design review file exists"
      })

    definition
  end

  @spec review_valid() :: RequirementDefinition.t()
  def review_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "review_valid",
        checker: ContextReviewValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Context design review is valid"
      })

    definition
  end

  @spec context_spec_file() :: RequirementDefinition.t()
  def context_spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec,
        artifact_type: :specification,
        description: "Context specification file exists"
      })

    definition
  end

  @spec context_spec_valid() :: RequirementDefinition.t()
  def context_spec_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_valid",
        checker: DocumentValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec,
        artifact_type: :specification,
        description: "Context specification is valid"
      })

    definition
  end

  @spec schema_spec_valid() :: RequirementDefinition.t()
  def schema_spec_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_valid",
        checker: DocumentValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Schema specification is valid"
      })

    definition
  end

  @spec default_requirements() :: [RequirementDefinition.t()]
  def default_requirements do
    [
      spec_file(),
      spec_valid(),
      implementation_file(),
      test_file(),
      test_spec_alignment(),
      tests_passing()
    ]
  end
end
