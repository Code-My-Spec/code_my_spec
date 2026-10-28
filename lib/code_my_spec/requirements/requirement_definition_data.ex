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

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Requirements.RequirementDefinition

  # Components describe implementation work. Test outcomes and acceptance
  # checks remain story requirements; markdown specs and reviews are inputs,
  # not additional work stages in the component graph.
  #
  # A container's dependencies gate its children through one `dependencies_met`
  # node: every dependency's exit points at it and it points at each child, so a
  # context with D dependencies and N children draws D + N edges rather than
  # D × N. The parent's own file waits on it too, for a context with no children
  # yet; with children that edge is redundant and the reduction drops it.
  def context_graph do
    [
      dependencies_met(8),
      implementation(9, :child, [8], :develop_context),
      implementation(11, :parent, [9, 8], :develop_context)
    ]
  end

  # A live context is a container: only its children have implementations.
  # No junction: the namespace has no implementation of its own, and a UI
  # surface's dependencies fan out to few children.
  def live_context_graph do
    [implementation(9, :child, [], :develop_live_context)]
  end

  def default_graph, do: [implementation(5, :self)]
  def schema_graph, do: [implementation(3, :self)]
  def behaviour_graph, do: [implementation(3, :self)]
  def json_graph, do: [implementation(2, :self)]
  def controller_graph, do: [implementation(4, :self)]
  def liveview_graph, do: [implementation(5, :self)]

  # Never work: always satisfied, and blocking is transitive, so a child behind
  # it is blocked exactly while some dependency is unfinished.
  defp dependencies_met(id) do
    new!(%{
      id: id,
      name: "dependencies_met",
      role: :coding,
      node_scope: :parent,
      check_type: :always,
      config: %{},
      satisfied_by: nil,
      artifact_type: :dependencies,
      description: "Where the container's dependencies gate its children",
      prerequisites: [],
      execution_type: :sub_agent
    })
  end

  defp implementation(id, node_scope, prerequisites \\ [], orchestrated_by \\ nil) do
    new!(%{
      id: id,
      name: "implementation_file",
      role: :coding,
      node_scope: node_scope,
      check_type: :file_exists,
      config: %{role: :implementation},
      satisfied_by: AgentTasks.ComponentCode,
      artifact_type: :code,
      description: "Component implementation file exists",
      prerequisites: prerequisites,
      execution_type: :sub_agent,
      orchestrated_by: orchestrated_by
    })
  end

  # Story requirements

  def story_graph do
    [
      new!(%{
        id: 1,
        name: "component_linked",
        role: :product,
        node_scope: :self,
        # Not `:field_present`: a story can carry a correct (derived) id for a
        # component not yet synced. Satisfied on its own when the sync creates it.
        check_type: :component_exists,
        config: %{},
        satisfied_by: AgentTasks.ArchitectureDesign,
        artifact_type: :dependencies,
        description: "Story has a linked surface component",
        prerequisites: []
      }),
      new!(%{
        id: 5,
        name: "three_amigos_complete",
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.BddRulesChecker, function: :sealed?},
        satisfied_by: AgentTasks.ThreeAmigos,
        artifact_type: :specification,
        description:
          "Three Amigos session sealed — persona, rules, scenarios, and every " <>
            "red card answered",
        prerequisites: [1],
        # Reads the seal, not the bar: a later question is the next
        # conversation. Automatic, because sealing already requires the bar; a
        # manual task lets its session's stops skip validation entirely.
        # See knowledge/requirements_graph/checkers, "Definitions".
        validation_type: :automatic
      }),
      # Makes post-seal open questions somebody's work. Gated on the seal: before
      # it, the same questions already block sealing.
      new!(%{
        id: 8,
        name: "questions_answered",
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.BddRulesChecker, function: :questions_answered?},
        satisfied_by: AgentTasks.ResolveQuestions,
        artifact_type: :specification,
        description:
          "Every question raised against this story, before or after sealing, is resolved or escalated",
        prerequisites: [5]
      }),
      new!(%{
        id: 2,
        name: "bdd_specs_exist",
        role: :coding,
        node_scope: :self,
        # Per criterion, so a criterion added after the first pass gets work.
        check_type: :bdd_specs_covered,
        config: %{role: :bdd_spec},
        satisfied_by: AgentTasks.WriteBddSpecs,
        artifact_type: :tests,
        description: "BDD spec files exist for story",
        prerequisites: [5],
        execution_type: :main_agent
      }),
      new!(%{
        id: 3,
        name: "ready_for_qa",
        role: :coding,
        node_scope: :self,
        # Reads a stamp, never analysis: the graph does not read problems.
        # Completing the task certifies the copy (`Promotion.certify/3`) and
        # stamps the commit, as `story_promoted` reads `promoted_version`.
        check_type: :field_present,
        config: %{field: :qa_ready_commit},
        satisfied_by: AgentTasks.ReadyForQa,
        artifact_type: :tests,
        description:
          "This story's working copy is certified ready for QA: a clean tree, every " <>
            "analyzer clean at HEAD, and the story's own specs green there. Completing " <>
            "this task certifies it and stamps the commit.",
        prerequisites: [2, 20],
        execution_type: :main_agent
      }),
      new!(%{
        id: 18,
        name: "story_promoted",
        role: :coding,
        node_scope: :self,
        # A question about state, not an act. Named for what it reads — one
        # column, `stories.promoted_version` — not as a git fact, which agents
        # verified against ancestry instead.
        check_type: :delegate,
        config: %{module: CodeMySpec.Promotion.RunningCopy, function: :running_copy_check},
        satisfied_by: AgentTasks.PromoteWork,
        artifact_type: :code,
        description:
          "This story carries a promotion stamp (`promoted_version`), written only " <>
            "by a promotion naming this story. Not a git check: code already on " <>
            "main does not satisfy it. Satisfy it by completing this task, which " <>
            "promotes the story.",
        # After QA: every working copy runs its own app, so QA tests the
        # story's copy directly, and promotion records that verified work landed.
        prerequisites: [4],
        execution_type: :main_agent
      }),
      new!(%{
        id: 4,
        name: "qa_complete",
        role: :qa,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Qa.Verdict, function: :complete_check},
        satisfied_by: AgentTasks.QaStory,
        artifact_type: :review,
        description: "QA complete: the latest DB-backed attempt is a valid pass",
        # Certification follows issue triage and resolution. QA starts only
        # after the working copy is certified ready.
        prerequisites: [3],
        execution_type: :sub_agent,
        # Automatic: completing requires a real attempt, and the evaluator's
        # `:skip` leaves a sub-agent's live task active rather than completing
        # it early. See knowledge/requirements_graph/checkers, "Definitions".
        validation_type: :automatic
      }),
      # Product triages every finding before coding submits blocking fixes.
      # Incoming findings at any severity must be accepted or dismissed;
      # accepted findings at the fix threshold become individual submission nodes.
      new!(%{
        id: 20,
        name: "story_issues_triaged",
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :story_triaged?},
        satisfied_by: AgentTasks.TriageIssues,
        artifact_type: :review,
        description: "No incoming issue on this story, at any severity",
        prerequisites: [1],
        execution_type: :main_agent
      }),
      # The UAT deploy, read from `Deploys` (a row whose `health_verified_at`
      # only a passing check sets), so a story cannot satisfy it by asserting
      # it. Prod belongs to the release process. Filtered out when `devops` is
      # `:off`, the default (`maybe_filter_devops/2`).
      #
      # Template ids must be unique: prerequisites resolve by id, and a reused
      # id silently rewires them. See knowledge/requirements_graph/checkers,
      # "Definitions".
      new!(%{
        id: 7,
        name: "deploy",
        role: :main,
        node_scope: :self,
        # The environment is config: environments are rows.
        check_type: :deployed,
        config: %{environment: "uat"},
        satisfied_by: AgentTasks.Deploy,
        artifact_type: :deployment,
        description: "Story is deployed to UAT and its health check passed",
        # Deploy follows promotion, which follows shared story QA. Individual
        # issue submissions join readiness upstream of that QA pass.
        prerequisites: [18],
        execution_type: :main_agent
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Project requirements
  # ═══════════════════════════════════════════════════════════════════════

  def project_graph do
    [
      new!(%{
        id: 13,
        name: "personas_complete",
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.PersonasChecker, function: :complete?},
        satisfied_by: AgentTasks.PersonaResearch,
        artifact_type: :specification,
        description:
          "Every persona researched — DB record + summary.md + sources.md (story linkage happens later via Three Amigos)",
        # The root: project setup is `cms new`'s job, not a requirement.
        prerequisites: [],
        # Manual so the stop hook doesn't short-circuit the multi-turn
        # intake conversation. The PM and agent need room to exchange
        # questions, do research, and write artifacts across many turns
        # before the checker is run.
        validation_type: :manual
      }),
      new!(%{
        id: 15,
        name: "stories_exist",
        # The main agent's: the initial story interview is project-scoped and
        # happens before there is a checkout to assign, while Three Amigos is
        # product's, per story, on the copy that builds it.
        role: :main,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.StoriesChecker, function: :exist?},
        satisfied_by: AgentTasks.StoryInterview,
        artifact_type: :specification,
        description:
          "At least one story exists for the project (acceptance criteria come later via Three Amigos)",
        prerequisites: [13],
        # Multi-turn PM intake conversation, as personas_complete.
        validation_type: :manual
      }),
      new!(%{
        id: 2,
        name: "technical_strategy",
        role: :main,
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/architecture/decisions.md"},
        satisfied_by: AgentTasks.TechnicalStrategy,
        artifact_type: :specification,
        description: "Technical strategy decisions file exists",
        prerequisites: [15]
      }),
      new!(%{
        id: 3,
        name: "code_generation",
        role: :coding,
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
        role: :qa,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.QaIntegrationPlanChecker, function: :evaluate},
        satisfied_by: AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified, or no integrations are required",
        prerequisites: [3],
        validation_type: :manual
      }),
      new!(%{
        id: 5,
        name: "architecture_designed",
        role: :main,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.ArchitectureChecker, function: :complete?},
        satisfied_by: AgentTasks.ArchitectureDesign,
        artifact_type: :specification,
        description:
          "Architecture written down (a proposal executed, or components authored) and every component is covered (story-linked, transitively depended on, or infrastructure)",
        prerequisites: [4]
      }),
      new!(%{
        id: 16,
        name: "spex_boundary_ready",
        role: :coding,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.SpexBoundaryChecker, function: :complete?},
        satisfied_by: AgentTasks.SpexBoundaryReady,
        artifact_type: :specification,
        description:
          "BDD spec boundary protections installed — framework Credo checks + fixtures bridge + project BDD spec plan",
        prerequisites: [5]
      }),
      # The node that keeps work moving. Placed after the boundary gate and
      # before issue triage because it is what puts story work in flight, and
      # there are no issues to triage until something has been built.
      #
      # Unsatisfied only when nothing is in progress and unassigned work exists.
      # It never assigns anything itself: sending and approving are two acts.
      new!(%{
        id: 17,
        name: "work_dispatched",
        role: :main,
        node_scope: :self,
        check_type: :delegate,
        config: %{
          module: CodeMySpec.Requirements.DispatchChecker,
          function: :dispatched?
        },
        artifact_type: :review,
        description:
          "Ready stories are grouped into epics and sent for approval when nothing is being built",
        prerequisites: [16]
      }),
      new!(%{
        id: 6,
        name: "issues_triaged",
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :triaged?},
        satisfied_by: AgentTasks.TriageIssues,
        artifact_type: :review,
        description: "All incoming QA issues have been triaged",
        prerequisites: [16]
      }),
      new!(%{
        id: 7,
        name: "issues_resolved",
        role: :coding,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :resolved?},
        satisfied_by: AgentTasks.FixIssues,
        artifact_type: :review,
        description: "All medium+ accepted issues have been resolved",
        prerequisites: [6]
      }),

      # QA chain — gated on qa_setup so all QA work has a plan, and run after
      # issues are *triaged*, not resolved.
      #
      # `qa_setup` opens all story-level work, so it waits on triage (always
      # satisfiable), never on resolution, which no one agent can always reach.
      # Resolution gates at the end: see `qa_journey_plan`.
      # See knowledge/requirements_graph/checkers, "Definitions".
      new!(%{
        id: 14,
        name: "qa_setup",
        role: :qa,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.QaDocumentChecker, function: :plan?},
        satisfied_by: AgentTasks.QaSetup,
        artifact_type: :review,
        description: "QA plan exists with App Overview, Tools Registry, and Seed Strategy",
        prerequisites: [6]
      }),
      # Where `issues_resolved` gates: the journey tests the build to ship, and
      # it is already the fan-in of every story's `qa_complete`.
      new!(%{
        id: 10,
        name: "qa_journey_plan",
        role: :qa,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.QaDocumentChecker, function: :journey_plan?},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :review,
        description: "QA journey plan exists and valid",
        prerequisites: [14, 7]
      }),
      new!(%{
        id: 11,
        name: "qa_journey_execute",
        role: :qa,
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_result.md"},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :review,
        description: "QA journey result exists and valid",
        prerequisites: [10]
      })
    ]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Story issue requirements, and accessors
  # ═══════════════════════════════════════════════════════════════════════

  def story_issue_graph do
    [
      new!(%{
        id: 1,
        name: "submitted",
        role: :coding,
        node_scope: :self,
        check_type: :field_present,
        config: %{field: :story_submission_ref},
        satisfied_by: AgentTasks.SubmitStoryIssue,
        artifact_type: :review,
        description: "The story issue fix is submitted for shared story QA",
        prerequisites: [],
        execution_type: :main_agent
      })
    ]
  end

  def story_requirements, do: story_graph()
  def project_requirements, do: project_graph()

  @doc """
  Every requirement name belonging to one role.

  The role lives on the definition, not the row, so `NodeRepository` narrows
  "is there work of my kind" by name. Read across every graph (coding owns
  `implementation_file` on components and `ready_for_qa` on stories) and
  deduplicated.

  Which definitions count is the role's `RoleProfile.requirements`: `:tagged`
  is every definition that names the role, `:untagged` every one naming none.
  """
  @spec requirement_names_for_role(atom()) :: [String.t()]
  def requirement_names_for_role(role) when is_atom(role) do
    all_graphs()
    |> Enum.filter(&offered_to?(&1, role))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc "Whether `role` is offered `definition`, by its `RoleProfile.requirements` selectors."
  @spec offered_to?(RequirementDefinition.t(), atom()) :: boolean()
  def offered_to?(definition, role) do
    Enum.any?(RoleProfile.requirements(role), &selects?(&1, definition, role))
  end

  defp selects?(:tagged, definition, role), do: definition.role == role
  defp selects?(:untagged, definition, _role), do: is_nil(definition.role)

  defp all_graphs do
    context_graph() ++
      live_context_graph() ++
      default_graph() ++
      schema_graph() ++
      behaviour_graph() ++
      json_graph() ++
      controller_graph() ++
      liveview_graph() ++
      story_graph() ++
      story_issue_graph() ++
      project_graph()
  end

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
