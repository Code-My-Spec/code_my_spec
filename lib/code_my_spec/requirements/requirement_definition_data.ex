defmodule CodeMySpec.Requirements.RequirementDefinitionData do
  @moduledoc """
  Central registry of all requirement definitions used across component types.
  Provides reusable requirement templates that combine checkers, session types,
  and categorization for consistent requirement checking.
  """

  alias CodeMySpec.Requirements.AcceptedIssuesChecker
  alias CodeMySpec.Requirements.AllBddSpecsPassingChecker
  alias CodeMySpec.Requirements.AllStoriesCompleteChecker
  alias CodeMySpec.Requirements.ArtifactExistenceChecker
  alias CodeMySpec.Requirements.BddSpecExistenceChecker
  alias CodeMySpec.Requirements.BddSpecPassingChecker
  alias CodeMySpec.Requirements.ComponentCompleteChecker
  alias CodeMySpec.Requirements.ComponentLinkedChecker
  alias CodeMySpec.Requirements.ContextReviewFileChecker
  alias CodeMySpec.Requirements.ContextReviewValidityChecker
  alias CodeMySpec.Requirements.DependencyChecker
  alias CodeMySpec.Requirements.DocumentValidityChecker
  alias CodeMySpec.Requirements.FileExistenceChecker
  alias CodeMySpec.Requirements.HierarchicalChecker
  alias CodeMySpec.Requirements.IncomingIssuesChecker
  alias CodeMySpec.Requirements.ProjectQaChecker
  alias CodeMySpec.Requirements.QaIntegrationPlanChecker
  alias CodeMySpec.Requirements.QaJourneyExecuteChecker
  alias CodeMySpec.Requirements.QaJourneyPlanChecker
  alias CodeMySpec.Requirements.QaJourneyWallabyChecker
  alias CodeMySpec.Requirements.QaPreflightChecker
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.SpecTestAlignmentChecker
  alias CodeMySpec.Requirements.StoryQaChecker
  alias CodeMySpec.Requirements.TestStatusChecker

  @spec spec_file() :: RequirementDefinition.t()
  def spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification file exists",
        prerequisites: []
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
        description: "Component specification is valid",
        prerequisites: ["spec_file"]
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
        description: "Component implementation file exists",
        prerequisites: ["spec_valid", "dependencies_satisfied"]
      })

    definition
  end

  @spec json_file() :: RequirementDefinition.t()
  def json_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "json_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Controller JSON view file exists",
        prerequisites: ["spec_valid"]
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
        description: "Component test file exists",
        prerequisites: ["spec_valid"],
        scope: :orchestrate
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
        description: "Test file implements all spec test assertions",
        prerequisites: ["test_file"]
      })

    definition
  end

  @spec tests_passing() :: RequirementDefinition.t()
  def tests_passing do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "tests_passing",
        checker: TestStatusChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: ["test_spec_alignment", "implementation_file"]
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
        description: "Component dependencies are satisfied",
        prerequisites: [],
        scope: :dependencies
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
        description: "Child component designs are complete",
        prerequisites: ["spec_valid"],
        scope: :children
      })

    definition
  end

  @spec children_implementations() :: RequirementDefinition.t()
  def children_implementations do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "children_implementations",
        checker: HierarchicalChecker,
        satisfied_by: CodeMySpec.AgentTasks.ContextImplementation,
        artifact_type: :hierarchy,
        description: "Child component implementations are complete",
        prerequisites: ["children_designs", "review_valid"],
        scope: :children
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
        description: "Context design review file exists",
        prerequisites: ["children_designs"]
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
        description: "Context design review is valid",
        prerequisites: ["review_file"]
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
        description: "Context specification file exists",
        prerequisites: [],
        scope: :orchestrate
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
        description: "Context specification is valid",
        prerequisites: ["spec_file"],
        scope: :orchestrate
      })

    definition
  end

  @spec context_implementation_file() :: RequirementDefinition.t()
  def context_implementation_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "implementation_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Context implementation file exists",
        prerequisites: ["children_implementations", "dependencies_satisfied"],
        scope: :orchestrate
      })

    definition
  end

  @spec context_test_file() :: RequirementDefinition.t()
  def context_test_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "test_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Context test file exists",
        prerequisites: ["children_implementations"],
        scope: :orchestrate
      })

    definition
  end

  @spec live_context_spec_file() :: RequirementDefinition.t()
  def live_context_spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.LiveContextSpec,
        artifact_type: :specification,
        description: "Live context specification file exists",
        prerequisites: [],
        scope: :orchestrate
      })

    definition
  end

  @spec live_context_spec_valid() :: RequirementDefinition.t()
  def live_context_spec_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_valid",
        checker: DocumentValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.LiveContextSpec,
        artifact_type: :specification,
        description: "Live context specification is valid",
        prerequisites: ["spec_file"],
        scope: :orchestrate
      })

    definition
  end

  @spec liveview_spec_file() :: RequirementDefinition.t()
  def liveview_spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        checker: FileExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "LiveView specification file exists",
        prerequisites: []
      })

    definition
  end

  @spec liveview_spec_valid() :: RequirementDefinition.t()
  def liveview_spec_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_valid",
        checker: DocumentValidityChecker,
        satisfied_by: CodeMySpec.AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "LiveView specification is valid",
        prerequisites: ["spec_file"]
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
        description: "Schema specification is valid",
        prerequisites: ["spec_file"]
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

  # --- Story requirement definitions ---

  @spec component_linked() :: RequirementDefinition.t()
  def component_linked do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "component_linked",
        checker: ComponentLinkedChecker,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureReview,
        artifact_type: :dependencies,
        description: "Story has a linked surface component",
        prerequisites: []
      })

    definition
  end

  @spec bdd_specs_exist() :: RequirementDefinition.t()
  def bdd_specs_exist do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "bdd_specs_exist",
        checker: BddSpecExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.WriteBddSpecs,
        artifact_type: :tests,
        description: "BDD spec files exist for story",
        prerequisites: ["component_linked"]
      })

    definition
  end

  @spec bdd_specs_passing() :: RequirementDefinition.t()
  def bdd_specs_passing do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "bdd_specs_passing",
        checker: BddSpecPassingChecker,
        satisfied_by: CodeMySpec.AgentTasks.FixBddSpecs,
        artifact_type: :tests,
        description: "BDD specs pass",
        prerequisites: ["component_complete"],
        scope: :orchestrate
      })

    definition
  end

  @spec component_complete() :: RequirementDefinition.t()
  def component_complete do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "component_complete",
        checker: ComponentCompleteChecker,
        satisfied_by: CodeMySpec.AgentTasks.DevelopComponent,
        artifact_type: :dependencies,
        description: "Linked component tree is fully implemented",
        prerequisites: ["bdd_specs_exist"],
        scope: :children
      })

    definition
  end

  @spec qa_complete() :: RequirementDefinition.t()
  def qa_complete do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_complete",
        checker: StoryQaChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaStory,
        artifact_type: :review,
        description: "QA brief and result artifacts valid",
        prerequisites: ["bdd_specs_passing"],
        scope: :orchestrate
      })

    definition
  end

  @spec story_requirements() :: [RequirementDefinition.t()]
  def story_requirements do
    [
      component_linked(),
      bdd_specs_exist(),
      component_complete(),
      bdd_specs_passing(),
      qa_complete()
    ]
  end

  # --- Project requirement definitions ---

  @spec project_setup() :: RequirementDefinition.t()
  def project_setup do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "project_setup",
        checker: CodeMySpec.Requirements.ProjectSetupChecker,
        satisfied_by: CodeMySpec.AgentTasks.ProjectSetup,
        artifact_type: :specification,
        description: "Project bootstrap setup is complete",
        prerequisites: [],
        scope: :local,
        validation_type: :manual,
        execution_type: :main_agent
      })

    definition
  end

  @spec technical_strategy() :: RequirementDefinition.t()
  def technical_strategy do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "technical_strategy",
        checker: ArtifactExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy,
        artifact_type: :specification,
        description: "Technical strategy decisions file exists",
        prerequisites: ["project_setup"],
        config: %{path: ".code_my_spec/architecture/decisions.md"}
      })

    definition
  end

  @spec qa_integration_plan() :: RequirementDefinition.t()
  def qa_integration_plan do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_integration_plan",
        checker: QaIntegrationPlanChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified",
        prerequisites: ["technical_strategy"],
        scope: :orchestrate,
        validation_type: :manual,
        execution_type: :main_agent
      })

    definition
  end

  @spec architecture_designed() :: RequirementDefinition.t()
  def architecture_designed do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "architecture_designed",
        checker: ArtifactExistenceChecker,
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign,
        artifact_type: :specification,
        description: "Architecture proposal executed",
        prerequisites: ["qa_integration_plan"],
        config: %{path: ".code_my_spec/architecture/overview.md"}
      })

    definition
  end

  @spec all_stories_complete() :: RequirementDefinition.t()
  def all_stories_complete do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "all_stories_complete",
        checker: AllStoriesCompleteChecker,
        satisfied_by: nil,
        artifact_type: :dependencies,
        description: "All story requirements satisfied",
        prerequisites: ["issues_resolved"],
        scope: :dependencies
      })

    definition
  end

  @spec project_qa() :: RequirementDefinition.t()
  def project_qa do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "project_qa",
        checker: ProjectQaChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaApp,
        artifact_type: :review,
        description: "QA summary exists and valid",
        prerequisites: ["all_stories_complete"]
      })

    definition
  end

  @spec issues_triaged() :: RequirementDefinition.t()
  def issues_triaged do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "issues_triaged",
        checker: IncomingIssuesChecker,
        satisfied_by: CodeMySpec.AgentTasks.TriageIssues,
        artifact_type: :review,
        description: "All incoming QA issues have been triaged",
        prerequisites: ["architecture_designed"]
      })

    definition
  end

  @spec issues_resolved() :: RequirementDefinition.t()
  def issues_resolved do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "issues_resolved",
        checker: AcceptedIssuesChecker,
        satisfied_by: CodeMySpec.AgentTasks.FixIssues,
        artifact_type: :review,
        description: "All medium+ accepted issues have been resolved",
        prerequisites: ["issues_triaged"],
        scope: :orchestrate
      })

    definition
  end

  @spec qa_preflight() :: RequirementDefinition.t()
  def qa_preflight do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_preflight",
        checker: QaPreflightChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaPreflight,
        artifact_type: :review,
        description: "App-level integration verification complete",
        prerequisites: ["all_stories_complete"],
        scope: :orchestrate
      })

    definition
  end

  @spec all_bdd_specs_passing() :: RequirementDefinition.t()
  def all_bdd_specs_passing do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "all_bdd_specs_passing",
        checker: AllBddSpecsPassingChecker,
        satisfied_by: CodeMySpec.AgentTasks.FixAllBddSpecs,
        artifact_type: :tests,
        description: "All BDD specs pass across all stories",
        prerequisites: ["qa_preflight"],
        scope: :orchestrate
      })

    definition
  end

  @spec qa_journey_plan() :: RequirementDefinition.t()
  def qa_journey_plan do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_journey_plan",
        checker: QaJourneyPlanChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaJourneyPlan,
        artifact_type: :review,
        description: "QA journey plan exists and valid",
        prerequisites: ["all_bdd_specs_passing"],
        scope: :pipeline
      })

    definition
  end

  @spec qa_journey_execute() :: RequirementDefinition.t()
  def qa_journey_execute do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_journey_execute",
        checker: QaJourneyExecuteChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaJourneyExecute,
        artifact_type: :review,
        description: "QA journey result exists and valid",
        prerequisites: ["qa_journey_plan"],
        scope: :orchestrate
      })

    definition
  end

  @spec qa_journey_wallaby() :: RequirementDefinition.t()
  def qa_journey_wallaby do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_journey_wallaby",
        checker: QaJourneyWallabyChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaJourneyWallaby,
        artifact_type: :tests,
        description: "Wallaby journey tests exist",
        prerequisites: ["qa_journey_execute"],
        scope: :orchestrate
      })

    definition
  end

  @spec project_requirements() :: [RequirementDefinition.t()]
  def project_requirements do
    [
      project_setup(),
      technical_strategy(),
      qa_integration_plan(),
      architecture_designed(),
      issues_triaged(),
      issues_resolved(),
      all_stories_complete(),
      qa_preflight(),
      all_bdd_specs_passing(),
      qa_journey_plan(),
      qa_journey_execute(),
      qa_journey_wallaby()
    ]
  end
end
