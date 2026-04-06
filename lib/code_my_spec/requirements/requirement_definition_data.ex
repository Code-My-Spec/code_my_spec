defmodule CodeMySpec.Requirements.RequirementDefinitionData do
  @moduledoc """
  Central registry of all requirement definitions used across component types.
  Each definition declares a `check_type` and `config` that the calculator
  uses to evaluate satisfaction.
  """

  alias CodeMySpec.Requirements.RequirementDefinition

  # ── Component requirements ──

  @spec spec_file() :: RequirementDefinition.t()
  def spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        check_type: :file_exists,
        config: %{role: :spec},
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
        check_type: :file_valid,
        config: %{role: :spec},
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
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists",
        prerequisites: ["test_spec_alignment"]
      })

    definition
  end

  @spec json_file() :: RequirementDefinition.t()
  def json_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "json_file",
        check_type: :file_exists,
        config: %{role: :json},
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Controller JSON view file exists",
        prerequisites: []
      })

    definition
  end

  @spec test_file() :: RequirementDefinition.t()
  def test_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "test_file",
        check_type: :file_exists,
        config: %{role: :test},
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
        check_type: :file_valid,
        config: %{role: :test},
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
        check_type: :tests_passing,
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: ["implementation_file"]
      })

    definition
  end

  # ── Context requirements ──

  @spec context_specs() :: RequirementDefinition.t()
  def context_specs do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "context_specs",
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: CodeMySpec.AgentTasks.ContextComponentSpecs,
        artifact_type: :hierarchy,
        description: "Child component specifications are complete",
        prerequisites: ["spec_valid"],
        scope: :children
      })

    definition
  end

  @spec context_implementation() :: RequirementDefinition.t()
  def context_implementation do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "context_implementation",
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: CodeMySpec.AgentTasks.ContextImplementation,
        artifact_type: :hierarchy,
        description: "Child component implementations are complete",
        prerequisites: ["review_valid"],
        scope: :children
      })

    definition
  end

  @spec review_file() :: RequirementDefinition.t()
  def review_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "review_file",
        check_type: :file_exists,
        config: %{role: :review},
        satisfied_by: CodeMySpec.AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Context design review file exists",
        prerequisites: []
      })

    definition
  end

  @spec review_valid() :: RequirementDefinition.t()
  def review_valid do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "review_valid",
        check_type: :file_valid,
        config: %{role: :review},
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
        check_type: :file_exists,
        config: %{role: :spec},
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
        check_type: :file_valid,
        config: %{role: :spec},
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
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: CodeMySpec.AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Context implementation file exists",
        prerequisites: ["review_valid"]
      })

    definition
  end

  @spec context_test_file() :: RequirementDefinition.t()
  def context_test_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "test_file",
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: CodeMySpec.AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Context test file exists",
        prerequisites: ["implementation_file"],
        scope: :orchestrate
      })

    definition
  end

  # ── LiveView / LiveContext spec variants ──

  @spec live_context_spec_file() :: RequirementDefinition.t()
  def live_context_spec_file do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "spec_file",
        check_type: :file_exists,
        config: %{role: :spec},
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
        check_type: :file_valid,
        config: %{role: :spec},
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
        check_type: :file_exists,
        config: %{role: :spec},
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
        check_type: :file_valid,
        config: %{role: :spec},
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
        check_type: :file_valid,
        config: %{role: :spec},
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

  # ── Story requirements ──

  @spec component_linked() :: RequirementDefinition.t()
  def component_linked do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "component_linked",
        check_type: :field_present,
        config: %{field: :component_id},
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign,
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
        check_type: :file_exists,
        config: %{role: :bdd_spec},
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
        check_type: :spex_passing,
        satisfied_by: CodeMySpec.AgentTasks.FixBddSpecs,
        artifact_type: :tests,
        description: "BDD specs pass",
        prerequisites: ["bdd_specs_exist"],
        scope: :orchestrate
      })

    definition
  end

  @spec qa_complete() :: RequirementDefinition.t()
  def qa_complete do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_complete",
        check_type: :file_exists,
        config: %{role: :qa_result},
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
      bdd_specs_passing(),
      qa_complete()
    ]
  end

  # ── Project requirements ──

  @spec project_setup() :: RequirementDefinition.t()
  def project_setup do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "project_setup",
        check_type: :delegate,
        config: %{module: CodeMySpec.AgentTasks.ProjectSetup, function: :check},
        satisfied_by: CodeMySpec.AgentTasks.ProjectSetup,
        artifact_type: :specification,
        description: "Project bootstrap setup is complete",
        prerequisites: [],
        scope: :local,
        validation_type: :automatic,
        execution_type: :main_agent
      })

    definition
  end

  @spec technical_strategy() :: RequirementDefinition.t()
  def technical_strategy do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "technical_strategy",
        check_type: :path_exists,
        config: %{path: ".code_my_spec/architecture/decisions.md"},
        satisfied_by: CodeMySpec.AgentTasks.TechnicalStrategy,
        artifact_type: :specification,
        description: "Technical strategy decisions file exists",
        prerequisites: ["project_setup"]
      })

    definition
  end

  @spec code_generation() :: RequirementDefinition.t()
  def code_generation do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "code_generation",
        check_type: :path_exists,
        config: %{path: ".code_my_spec/tasks/code_generation.sh"},
        satisfied_by: CodeMySpec.AgentTasks.CodeGeneration,
        artifact_type: :code,
        description: "Code generators have been run and recorded",
        prerequisites: ["technical_strategy"],
        scope: :local,
        execution_type: :main_agent
      })

    definition
  end

  @spec qa_integration_plan() :: RequirementDefinition.t()
  def qa_integration_plan do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_integration_plan",
        check_type: :path_exists,
        config: %{path_prefix: ".code_my_spec/integrations/"},
        satisfied_by: CodeMySpec.AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified",
        prerequisites: ["code_generation"],
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
        check_type: :path_exists,
        config: %{path: ".code_my_spec/architecture/proposal.md"},
        satisfied_by: CodeMySpec.AgentTasks.ArchitectureDesign,
        artifact_type: :specification,
        description: "Architecture proposal executed",
        prerequisites: ["qa_integration_plan"]
      })

    definition
  end

  @spec issues_triaged() :: RequirementDefinition.t()
  def issues_triaged do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "issues_triaged",
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :triaged?},
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
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :resolved?},
        satisfied_by: CodeMySpec.AgentTasks.FixIssues,
        artifact_type: :review,
        description: "All medium+ accepted issues have been resolved",
        prerequisites: ["issues_triaged"]
      })

    definition
  end

  @spec qa_preflight() :: RequirementDefinition.t()
  def qa_preflight do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_preflight",
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/preflight.md"},
        satisfied_by: CodeMySpec.AgentTasks.QaPreflight,
        artifact_type: :review,
        description: "App-level integration verification complete",
        prerequisites: [],
        scope: :orchestrate
      })

    definition
  end

  @spec all_bdd_specs_passing() :: RequirementDefinition.t()
  def all_bdd_specs_passing do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "all_bdd_specs_passing",
        check_type: :spex_passing,
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
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_plan.md"},
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
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_result.md"},
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
        check_type: :path_exists,
        config: %{path_prefix: "test/e2e/"},
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
      code_generation(),
      qa_integration_plan(),
      architecture_designed(),
      issues_triaged(),
      issues_resolved(),
      qa_preflight(),
      all_bdd_specs_passing(),
      qa_journey_plan(),
      qa_journey_execute(),
      qa_journey_wallaby()
    ]
  end
end
