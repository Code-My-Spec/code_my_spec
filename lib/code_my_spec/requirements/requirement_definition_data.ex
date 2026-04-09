defmodule CodeMySpec.Requirements.RequirementDefinitionData do
  @moduledoc """
  Graph templates for requirement DAGs.

  Each template defines nodes with integer IDs and prerequisite edges.
  `node_scope` indicates how nodes are instantiated:

  - `:parent` — stamped once for the parent entity
  - `:child`  — stamped once per child entity
  - `:self`   — stamped once for the entity itself (no parent/child relationship)

  When the graph instantiates a template for a component with children,
  `:child` nodes are duplicated per child. Prerequisites reference IDs
  within the template — cross-boundary edges are explicit.
  """

  alias CodeMySpec.Requirements.RequirementDefinition

  # ═══════════════════════════════════════════════════════════════════════
  # Context graph template
  #
  # Parent: spec → valid → [children specs] → review → valid → [children impl] → impl → test → passing
  # ═══════════════════════════════════════════════════════════════════════

  def context_graph do
    [
      # Parent spec phase
      def_node(1, "spec_file", :parent, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ContextSpec, :specification,
        "Context specification file exists", []),

      def_node(2, "spec_valid", :parent, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.ContextSpec, :specification,
        "Context specification is valid", [1]),

      # Child spec phase (stamped per child)
      def_node(3, "spec_file", :child, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Component specification file exists", [2]),

      def_node(4, "spec_valid", :child, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Component specification is valid", [3]),

      # Parent review phase (fan-in: all children spec_valid → review)
      def_node(5, "review_file", :parent, :file_exists, %{role: :review},
        CodeMySpec.AgentTasks.ContextDesignReview, :review,
        "Context design review file exists", [4]),

      def_node(6, "review_valid", :parent, :file_valid, %{role: :review},
        CodeMySpec.AgentTasks.ContextDesignReview, :review,
        "Context design review is valid", [5]),

      # Child test + implementation phase (after review)
      def_node(7, "test_file", :child, :file_exists, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Component test file exists", [6, 4]),

      def_node(8, "test_spec_alignment", :child, :file_valid, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Test file implements all spec test assertions", [7]),

      def_node(9, "implementation_file", :child, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component implementation file exists", [8]),

      def_node(10, "tests_passing", :child, :tests_passing, nil,
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component tests are passing", [9]),

      # Parent implementation phase (fan-in: all children done → parent impl)
      def_node(11, "implementation_file", :parent, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Context implementation file exists", [10, 6]),

      def_node(12, "test_file", :parent, :file_exists, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Context test file exists", [11]),

      def_node(13, "test_spec_alignment", :parent, :file_valid, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Test file implements all spec test assertions", [12]),

      def_node(14, "tests_passing", :parent, :tests_passing, nil,
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Context tests are passing", [13])
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Live context graph template (no implementation/tests on parent)
  # ═══════════════════════════════════════════════════════════════════════

  def live_context_graph do
    [
      def_node(1, "spec_file", :parent, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.LiveContextSpec, :specification,
        "Live context specification file exists", []),

      def_node(2, "spec_valid", :parent, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.LiveContextSpec, :specification,
        "Live context specification is valid", [1]),

      # Child spec phase
      def_node(3, "spec_file", :child, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.LiveViewSpec, :specification,
        "Component specification file exists", [2]),

      def_node(4, "spec_valid", :child, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.LiveViewSpec, :specification,
        "Component specification is valid", [3]),

      # Parent review
      def_node(5, "review_file", :parent, :file_exists, %{role: :review},
        CodeMySpec.AgentTasks.ContextDesignReview, :review,
        "Design review file exists", [4]),

      def_node(6, "review_valid", :parent, :file_valid, %{role: :review},
        CodeMySpec.AgentTasks.ContextDesignReview, :review,
        "Design review is valid", [5]),

      # Child test + implementation (after review)
      def_node(7, "test_file", :child, :file_exists, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Component test file exists", [6, 4]),

      def_node(8, "test_spec_alignment", :child, :file_valid, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Test file implements all spec test assertions", [7]),

      def_node(9, "implementation_file", :child, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component implementation file exists", [8]),

      def_node(10, "tests_passing", :child, :tests_passing, nil,
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component tests are passing", [9])
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Leaf component templates (no parent/child, just :self)
  # ═══════════════════════════════════════════════════════════════════════

  def default_graph do
    [
      def_node(1, "spec_file", :self, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Component specification file exists", []),

      def_node(2, "spec_valid", :self, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Component specification is valid", [1]),

      def_node(3, "test_file", :self, :file_exists, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Component test file exists", [2]),

      def_node(4, "test_spec_alignment", :self, :file_valid, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Test file implements all spec test assertions", [3]),

      def_node(5, "implementation_file", :self, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component implementation file exists", [4]),

      def_node(6, "tests_passing", :self, :tests_passing, nil,
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component tests are passing", [5])
    ]
  end

  def schema_graph do
    [
      def_node(1, "spec_file", :self, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Schema specification file exists", []),

      def_node(2, "spec_valid", :self, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Schema specification is valid", [1]),

      def_node(3, "implementation_file", :self, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Schema implementation file exists", [2])
    ]
  end

  def behaviour_graph do
    [
      def_node(1, "spec_file", :self, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Behaviour specification file exists", []),

      def_node(2, "spec_valid", :self, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "Behaviour specification is valid", [1]),

      def_node(3, "implementation_file", :self, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Behaviour implementation file exists", [2])
    ]
  end

  def json_graph do
    [
      def_node(1, "spec_file", :self, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.ComponentSpec, :specification,
        "JSON view specification file exists", []),

      def_node(2, "implementation_file", :self, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "JSON view implementation file exists", [1])
    ]
  end

  def liveview_graph do
    [
      def_node(1, "spec_file", :self, :file_exists, %{role: :spec},
        CodeMySpec.AgentTasks.LiveViewSpec, :specification,
        "LiveView specification file exists", []),

      def_node(2, "spec_valid", :self, :file_valid, %{role: :spec},
        CodeMySpec.AgentTasks.LiveViewSpec, :specification,
        "LiveView specification is valid", [1]),

      def_node(3, "test_file", :self, :file_exists, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Component test file exists", [2]),

      def_node(4, "test_spec_alignment", :self, :file_valid, %{role: :test},
        CodeMySpec.AgentTasks.ComponentTest, :tests,
        "Test file implements all spec test assertions", [3]),

      def_node(5, "implementation_file", :self, :file_exists, %{role: :implementation},
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component implementation file exists", [4]),

      def_node(6, "tests_passing", :self, :tests_passing, nil,
        CodeMySpec.AgentTasks.ComponentCode, :code,
        "Component tests are passing", [5])
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Story requirements
  # ═══════════════════════════════════════════════════════════════════════

  def story_graph do
    [
      def_node(1, "component_linked", :self, :field_present, %{field: :component_id},
        CodeMySpec.AgentTasks.ArchitectureDesign, :dependencies,
        "Story has a linked surface component", []),

      def_node(2, "bdd_specs_exist", :self, :file_exists, %{role: :bdd_spec},
        CodeMySpec.AgentTasks.WriteBddSpecs, :tests,
        "BDD spec files exist for story", [1]),

      def_node(3, "bdd_specs_passing", :self, :spex_passing, nil,
        CodeMySpec.AgentTasks.FixBddSpecs, :tests,
        "BDD specs pass", [2]),

      def_node(4, "qa_complete", :self, :file_exists, %{role: :qa_result},
        CodeMySpec.AgentTasks.QaStory, :review,
        "QA brief and result artifacts valid", [3])
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Project requirements
  # ═══════════════════════════════════════════════════════════════════════

  def project_graph do
    [
      def_node(1, "project_setup", :self, :delegate,
        %{module: CodeMySpec.AgentTasks.ProjectSetup, function: :check},
        CodeMySpec.AgentTasks.ProjectSetup, :specification,
        "Project bootstrap setup is complete", []),

      def_node(2, "technical_strategy", :self, :path_exists,
        %{path: ".code_my_spec/architecture/decisions.md"},
        CodeMySpec.AgentTasks.TechnicalStrategy, :specification,
        "Technical strategy decisions file exists", [1]),

      def_node(3, "code_generation", :self, :path_exists,
        %{path: ".code_my_spec/tasks/code_generation.sh"},
        CodeMySpec.AgentTasks.CodeGeneration, :code,
        "Code generators have been run and recorded", [2]),

      def_node(4, "qa_integration_plan", :self, :path_exists,
        %{path_prefix: ".code_my_spec/integrations/"},
        CodeMySpec.AgentTasks.QaIntegrationPlan, :specification,
        "Integration specs exist and all verified", [3],
        validation_type: :manual),

      def_node(5, "architecture_designed", :self, :path_exists,
        %{path: ".code_my_spec/architecture/proposal.md"},
        CodeMySpec.AgentTasks.ArchitectureDesign, :specification,
        "Architecture proposal executed", [4]),

      def_node(6, "issues_triaged", :self, :delegate,
        %{module: CodeMySpec.Requirements.IssuesChecker, function: :triaged?},
        CodeMySpec.AgentTasks.TriageIssues, :review,
        "All incoming QA issues have been triaged", [5]),

      def_node(7, "issues_resolved", :self, :delegate,
        %{module: CodeMySpec.Requirements.IssuesChecker, function: :resolved?},
        CodeMySpec.AgentTasks.FixIssues, :review,
        "All medium+ accepted issues have been resolved", [6]),

      # QA chain (separate from main — qa_preflight has no prereqs in this chain)
      def_node(8, "qa_preflight", :self, :path_exists,
        %{path: ".code_my_spec/qa/preflight.md"},
        CodeMySpec.AgentTasks.QaPreflight, :review,
        "App-level integration verification complete", []),

      def_node(9, "all_bdd_specs_passing", :self, :spex_passing, nil,
        CodeMySpec.AgentTasks.FixAllBddSpecs, :tests,
        "All BDD specs pass across all stories", [8]),

      def_node(10, "qa_journey_plan", :self, :path_exists,
        %{path: ".code_my_spec/qa/journey_plan.md"},
        CodeMySpec.AgentTasks.QaJourneyPlan, :review,
        "QA journey plan exists and valid", [9]),

      def_node(11, "qa_journey_execute", :self, :path_exists,
        %{path: ".code_my_spec/qa/journey_result.md"},
        CodeMySpec.AgentTasks.QaJourneyExecute, :review,
        "QA journey result exists and valid", [10]),

      def_node(12, "qa_journey_wallaby", :self, :path_exists,
        %{path_prefix: "test/e2e/"},
        CodeMySpec.AgentTasks.QaJourneyWallaby, :tests,
        "Wallaby journey tests exist", [11])
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Legacy accessors (used by existing code — will be removed as graph
  # instantiation takes over)
  # ═══════════════════════════════════════════════════════════════════════

  def story_requirements, do: story_graph()
  def project_requirements, do: project_graph()
  def default_requirements, do: default_graph()

  # ═══════════════════════════════════════════════════════════════════════
  # Graph template lookup
  # ═══════════════════════════════════════════════════════════════════════

  @doc "Returns the graph template for a component type."
  def graph_for_type("context"), do: context_graph()
  def graph_for_type("coordination_context"), do: context_graph()
  def graph_for_type("live_context"), do: live_context_graph()
  def graph_for_type("schema"), do: schema_graph()
  def graph_for_type("behaviour"), do: behaviour_graph()
  def graph_for_type("json"), do: json_graph()
  def graph_for_type("liveview"), do: liveview_graph()
  def graph_for_type("liveview_component"), do: liveview_graph()
  def graph_for_type(_), do: default_graph()

  # ═══════════════════════════════════════════════════════════════════════
  # Node builder
  # ═══════════════════════════════════════════════════════════════════════

  defp def_node(id, name, node_scope, check_type, config, satisfied_by, artifact_type, description, prerequisites, opts \\ []) do
    {:ok, definition} =
      RequirementDefinition.new(%{
        id: id,
        name: name,
        node_scope: node_scope,
        check_type: check_type,
        config: config || %{},
        satisfied_by: satisfied_by,
        artifact_type: artifact_type,
        description: description,
        prerequisites: prerequisites,
        validation_type: Keyword.get(opts, :validation_type, :automatic),
        execution_type: Keyword.get(opts, :execution_type, :main_agent)
      })

    definition
  end
end
