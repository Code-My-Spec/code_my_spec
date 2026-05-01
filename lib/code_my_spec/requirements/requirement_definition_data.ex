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

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Requirements.RequirementDefinition

  # ═══════════════════════════════════════════════════════════════════════
  # Context graph template
  #
  # Parent: spec → valid → [children specs] → review → valid → [children impl] → impl → test → passing
  # ═══════════════════════════════════════════════════════════════════════

  def context_graph do
    [
      # Parent spec phase
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ContextSpec,
        artifact_type: :specification,
        description: "Context specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :parent,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ContextSpec,
        artifact_type: :specification,
        description: "Context specification is valid",
        prerequisites: [1]
      }),

      # Child spec phase (stamped per child, executed by sub-agents)
      new!(%{
        id: 3,
        name: "spec_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification file exists",
        prerequisites: [2],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 4,
        name: "spec_valid",
        node_scope: :child,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification is valid",
        prerequisites: [3],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),

      # Parent review phase (fan-in: all children spec_valid → review)
      new!(%{
        id: 5,
        name: "review_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :review},
        satisfied_by: AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Context design review file exists",
        prerequisites: [4],
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 6,
        name: "review_valid",
        node_scope: :parent,
        check_type: :file_valid,
        config: %{role: :review},
        satisfied_by: AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Context design review is valid",
        prerequisites: [5],
        orchestrated_by: :develop_context
      }),

      # Child test + implementation phase (after review, executed by sub-agents)
      new!(%{
        id: 7,
        name: "test_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Component test file exists",
        prerequisites: [6],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 8,
        name: "test_spec_alignment",
        node_scope: :child,
        check_type: :file_valid,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        prerequisites: [7],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 9,
        name: "implementation_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists",
        prerequisites: [6],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 10,
        name: "tests_passing",
        node_scope: :child,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [9],
        execution_type: :sub_agent,
        orchestrated_by: :develop_context
      }),

      # Parent implementation phase (fan-in: all children done → parent impl)
      # Prerequisites include child implementation_file (9) so schemas (which lack
      # test_file/tests_passing) still gate the parent correctly.
      new!(%{
        id: 11,
        name: "implementation_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Context implementation file exists",
        prerequisites: [8, 9, 10, 6],
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 12,
        name: "test_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Context test file exists",
        prerequisites: [11],
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 13,
        name: "test_spec_alignment",
        node_scope: :parent,
        check_type: :file_valid,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        prerequisites: [12],
        orchestrated_by: :develop_context
      }),
      new!(%{
        id: 14,
        name: "tests_passing",
        node_scope: :parent,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Context tests are passing",
        prerequisites: [13],
        orchestrated_by: :develop_context
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Live context graph template (no implementation/tests on parent)
  # ═══════════════════════════════════════════════════════════════════════

  def live_context_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveContextSpec,
        artifact_type: :specification,
        description: "Live context specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :parent,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveContextSpec,
        artifact_type: :specification,
        description: "Live context specification is valid",
        prerequisites: [1]
      }),

      # Child spec phase
      new!(%{
        id: 3,
        name: "spec_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "Component specification file exists",
        prerequisites: [2],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      }),
      new!(%{
        id: 4,
        name: "spec_valid",
        node_scope: :child,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "Component specification is valid",
        prerequisites: [3],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      }),

      # Parent review
      new!(%{
        id: 5,
        name: "review_file",
        node_scope: :parent,
        check_type: :file_exists,
        config: %{role: :review},
        satisfied_by: AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Design review file exists",
        prerequisites: [4],
        orchestrated_by: :develop_live_context
      }),
      new!(%{
        id: 6,
        name: "review_valid",
        node_scope: :parent,
        check_type: :file_valid,
        config: %{role: :review},
        satisfied_by: AgentTasks.ContextDesignReview,
        artifact_type: :review,
        description: "Design review is valid",
        prerequisites: [5],
        orchestrated_by: :develop_live_context
      }),

      # Child test + implementation (after review, executed by sub-agents)
      new!(%{
        id: 7,
        name: "test_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Component test file exists",
        prerequisites: [6, 4],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      }),
      new!(%{
        id: 8,
        name: "test_spec_alignment",
        node_scope: :child,
        check_type: :file_valid,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        prerequisites: [7],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      }),
      new!(%{
        id: 9,
        name: "implementation_file",
        node_scope: :child,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists",
        prerequisites: [6],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      }),
      new!(%{
        id: 10,
        name: "tests_passing",
        node_scope: :child,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [9],
        execution_type: :sub_agent,
        orchestrated_by: :develop_live_context
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Leaf component templates (no parent/child, just :self)
  # ═══════════════════════════════════════════════════════════════════════

  def default_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Component specification is valid",
        prerequisites: [1]
      }),
      new!(%{
        id: 3,
        name: "test_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Component test file exists",
        prerequisites: [2]
      }),
      new!(%{
        id: 4,
        name: "test_spec_alignment",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        prerequisites: [3]
      }),
      new!(%{
        id: 5,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists",
        prerequisites: [2]
      }),
      new!(%{
        id: 6,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [5]
      })
    ]
  end

  def schema_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Schema specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Schema specification is valid",
        prerequisites: [1]
      }),
      new!(%{
        id: 3,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Schema implementation file exists",
        prerequisites: [2]
      })
    ]
  end

  def behaviour_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Behaviour specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "Behaviour specification is valid",
        prerequisites: [1]
      }),
      new!(%{
        id: 3,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Behaviour implementation file exists",
        prerequisites: [2]
      })
    ]
  end

  def json_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ComponentSpec,
        artifact_type: :specification,
        description: "JSON view specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "JSON view implementation file exists",
        prerequisites: [1]
      })
    ]
  end

  def controller_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ControllerSpec,
        artifact_type: :specification,
        description: "Controller specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.ControllerSpec,
        artifact_type: :specification,
        description: "Controller specification is valid",
        prerequisites: [1]
      }),
      new!(%{
        id: 3,
        name: "test_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Controller test file exists",
        prerequisites: [2]
      }),
      new!(%{
        id: 4,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Controller implementation file exists",
        prerequisites: [3]
      }),
      new!(%{
        id: 5,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Controller tests are passing",
        prerequisites: [4]
      })
    ]
  end

  def liveview_graph do
    [
      new!(%{
        id: 1,
        name: "spec_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "LiveView specification file exists",
        prerequisites: []
      }),
      new!(%{
        id: 2,
        name: "spec_valid",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :spec},
        satisfied_by: AgentTasks.LiveViewSpec,
        artifact_type: :specification,
        description: "LiveView specification is valid",
        prerequisites: [1]
      }),
      new!(%{
        id: 3,
        name: "test_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Component test file exists",
        prerequisites: [2]
      }),
      new!(%{
        id: 4,
        name: "test_spec_alignment",
        node_scope: :self,
        check_type: :file_valid,
        config: %{role: :test},
        satisfied_by: AgentTasks.ComponentTest,
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        prerequisites: [3],
        execution_type: :sub_agent
      }),
      new!(%{
        id: 5,
        name: "implementation_file",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :implementation},
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component implementation file exists",
        prerequisites: [4]
      }),
      new!(%{
        id: 6,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [5]
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Story requirements
  # ═══════════════════════════════════════════════════════════════════════

  def story_graph do
    [
      new!(%{
        id: 1,
        name: "component_linked",
        node_scope: :self,
        check_type: :field_present,
        config: %{field: :component_id},
        satisfied_by: AgentTasks.ArchitectureDesign,
        artifact_type: :dependencies,
        description: "Story has a linked surface component",
        prerequisites: []
      }),
      new!(%{
        id: 5,
        name: "three_amigos_complete",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.BddRulesChecker, function: :complete?},
        satisfied_by: AgentTasks.ThreeAmigos,
        artifact_type: :specification,
        description:
          "Three Amigos session complete — persona linked, rules and scenarios populated",
        prerequisites: [1],
        # Manual so the stop hook doesn't short-circuit the multi-turn
        # PM/agent intake conversation. Same rationale as personas_complete.
        validation_type: :manual
      }),
      new!(%{
        id: 2,
        name: "bdd_specs_exist",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :bdd_spec},
        satisfied_by: AgentTasks.WriteBddSpecs,
        artifact_type: :tests,
        description: "BDD spec files exist for story",
        prerequisites: [5]
      }),
      new!(%{
        id: 3,
        name: "bdd_specs_passing",
        node_scope: :self,
        check_type: :spex_passing,
        satisfied_by: AgentTasks.FixBddSpecs,
        artifact_type: :tests,
        description: "BDD specs pass",
        prerequisites: [2]
      }),
      new!(%{
        id: 4,
        name: "qa_complete",
        node_scope: :self,
        check_type: :file_exists,
        config: %{role: :qa_result},
        satisfied_by: AgentTasks.QaStory,
        artifact_type: :review,
        description: "QA brief and result artifacts valid",
        prerequisites: [3]
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Project requirements
  # ═══════════════════════════════════════════════════════════════════════

  def project_graph do
    [
      new!(%{
        id: 1,
        name: "project_setup",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: AgentTasks.ProjectSetup, function: :check},
        satisfied_by: AgentTasks.ProjectSetup,
        artifact_type: :specification,
        description: "Project bootstrap setup is complete",
        prerequisites: [],
        # Multi-step status report — always show the per-step
        # checklist, not just when the overall requirement is unsatisfied.
        render_command_always?: true
      }),
      new!(%{
        id: 2,
        name: "technical_strategy",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/architecture/decisions.md"},
        satisfied_by: AgentTasks.TechnicalStrategy,
        artifact_type: :specification,
        description: "Technical strategy decisions file exists",
        prerequisites: [15]
      }),
      new!(%{
        id: 13,
        name: "personas_complete",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.PersonasChecker, function: :complete?},
        satisfied_by: AgentTasks.PersonaResearch,
        artifact_type: :specification,
        description:
          "At least one persona researched — DB record + summary.md + sources.md (story linkage happens later via Three Amigos)",
        prerequisites: [1],
        # Manual so the stop hook doesn't short-circuit the multi-turn
        # intake conversation. The PM and agent need room to exchange
        # questions, do research, and write artifacts across many turns
        # before the checker is run.
        validation_type: :manual
      }),
      new!(%{
        id: 15,
        name: "stories_exist",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.StoriesChecker, function: :exist?},
        satisfied_by: AgentTasks.StoryInterview,
        artifact_type: :specification,
        description:
          "At least one story exists for the project (acceptance criteria come later via Three Amigos)",
        prerequisites: [13],
        # Multi-turn PM intake conversation — same rationale as
        # personas_complete and three_amigos_complete.
        validation_type: :manual
      }),
      new!(%{
        id: 3,
        name: "code_generation",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/tasks/code_generation.sh"},
        satisfied_by: AgentTasks.CodeGeneration,
        artifact_type: :code,
        description: "Code generators have been run and recorded",
        prerequisites: [2]
      }),
      new!(%{
        id: 4,
        name: "qa_integration_plan",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path_prefix: ".code_my_spec/integrations/"},
        satisfied_by: AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified",
        prerequisites: [3],
        validation_type: :manual
      }),
      new!(%{
        id: 5,
        name: "architecture_designed",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/architecture/proposal.md"},
        satisfied_by: AgentTasks.ArchitectureDesign,
        artifact_type: :specification,
        description: "Architecture proposal executed",
        prerequisites: [4]
      }),
      new!(%{
        id: 6,
        name: "issues_triaged",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :triaged?},
        satisfied_by: AgentTasks.TriageIssues,
        artifact_type: :review,
        description: "All incoming QA issues have been triaged",
        prerequisites: [5]
      }),
      new!(%{
        id: 7,
        name: "issues_resolved",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :resolved?},
        satisfied_by: AgentTasks.FixIssues,
        artifact_type: :review,
        description: "All medium+ accepted issues have been resolved",
        prerequisites: [6]
      }),

      # QA chain — gated on qa_setup so all QA work has a plan, and run after
      # issues are resolved so per-story work begins from a clean slate.
      new!(%{
        id: 14,
        name: "qa_setup",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/plan.md"},
        satisfied_by: AgentTasks.QaSetup,
        artifact_type: :review,
        description:
          "QA plan exists with App Overview, Tools Registry, and Seed Strategy",
        prerequisites: [7]
      }),
      new!(%{
        id: 8,
        name: "qa_preflight",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/preflight.md"},
        satisfied_by: AgentTasks.QaPreflight,
        artifact_type: :review,
        description: "App-level integration verification complete",
        prerequisites: [14]
      }),
      new!(%{
        id: 9,
        name: "all_bdd_specs_passing",
        node_scope: :self,
        check_type: :spex_passing,
        satisfied_by: AgentTasks.FixAllBddSpecs,
        artifact_type: :tests,
        description: "All BDD specs pass across all stories",
        prerequisites: [8]
      }),
      new!(%{
        id: 10,
        name: "qa_journey_plan",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_plan.md"},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :review,
        description: "QA journey plan exists and valid",
        prerequisites: [9]
      }),
      new!(%{
        id: 11,
        name: "qa_journey_execute",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_result.md"},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :review,
        description: "QA journey result exists and valid",
        prerequisites: [10]
      }),
      new!(%{
        id: 12,
        name: "qa_journey_wallaby",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path_prefix: "test/e2e/"},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :tests,
        description: "Wallaby journey tests exist",
        prerequisites: [11]
      })
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
  def graph_for_type("controller"), do: controller_graph()
  def graph_for_type("schema"), do: schema_graph()
  def graph_for_type("behaviour"), do: behaviour_graph()
  def graph_for_type("json"), do: json_graph()
  def graph_for_type("liveview"), do: liveview_graph()
  def graph_for_type("liveview_component"), do: liveview_graph()
  def graph_for_type("infrastructure"), do: []
  def graph_for_type(_), do: default_graph()

  # ═══════════════════════════════════════════════════════════════════════
  # Node builder
  # ═══════════════════════════════════════════════════════════════════════

  defp new!(attrs) do
    {:ok, definition} = RequirementDefinition.new(attrs)
    definition
  end
end
