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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_context,
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        orchestrated_by: :develop_live_context,
        execution_type: :sub_agent
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
        orchestrated_by: :develop_live_context,
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
      }),
      new!(%{
        id: 6,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [5],
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
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
        prerequisites: [3],
        execution_type: :sub_agent
      }),
      new!(%{
        id: 5,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Controller tests are passing",
        prerequisites: [4],
        execution_type: :sub_agent
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
        prerequisites: [],
        execution_type: :sub_agent
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
        prerequisites: [1],
        execution_type: :sub_agent
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
        prerequisites: [2],
        execution_type: :sub_agent
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
        prerequisites: [4],
        execution_type: :sub_agent
      }),
      new!(%{
        id: 6,
        name: "tests_passing",
        node_scope: :self,
        check_type: :tests_passing,
        satisfied_by: AgentTasks.ComponentCode,
        artifact_type: :code,
        description: "Component tests are passing",
        prerequisites: [5],
        execution_type: :sub_agent
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
        prerequisites: [5],
        execution_type: :main_agent
      }),
      new!(%{
        id: 3,
        name: "bdd_specs_passing",
        node_scope: :self,
        check_type: :field_true,
        config: %{field: :specs_ready},
        satisfied_by: AgentTasks.FixBddSpecs,
        artifact_type: :tests,
        # Phrased as the step, not the state. "BDD specs have gone green on a
        # fresh spex run" reads as a fact about the world, so an agent whose
        # sweep had gone green read the unsatisfied node as a broken gate rather
        # than as an evaluation it had not run yet.
        description: "BDD specs green on a fresh spex run, and evaluated to record it",
        prerequisites: [2],
        execution_type: :main_agent
      }),
      new!(%{
        id: 4,
        name: "qa_complete",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Qa, function: :complete_check},
        satisfied_by: AgentTasks.QaStory,
        artifact_type: :review,
        description: "QA complete: at least one valid DB-backed pass attempt exists",
        prerequisites: [3],
        execution_type: :sub_agent,
        subagent_role: :qa,
        # Manual so the stop hook does not complete the sub-agent's task out
        # from under it. Same rationale as `three_amigos_complete` above, and
        # the omission here was a real defect (`7f79b855`): `execution_type:
        # :sub_agent` says a sub-agent does this work, while the default
        # `:automatic` says the stop hook finishes it, and `Session.active_task/1`
        # selects by status alone with no reference to `agent_id`. So the
        # parent's own stop picked up the QA sub-agent's live task and completed
        # it — before any attempt existed, discarding the run and leaving no
        # record that QA had been tried.
        #
        # `QaStory.evaluate/2` carries a `subagent_owns?` guard that was added
        # to compensate, and it cannot: its two available answers are `:valid`,
        # which completes, and `:invalid`, which files feedback against the
        # parent. Manual is skipped in `TaskEvaluator` *above* the evaluator, so
        # the guard stops being reached at all.
        validation_type: :manual
      }),
      # Issues QA raised against *this* story, resolved before it is released.
      #
      # The project-level `issues_resolved` runs once, at the end, over the
      # whole queue — the right place for issues nobody attributed to a story,
      # and the wrong place for a blocker that this story's own QA pass just
      # found. Waiting until then means the story ships, or the whole cycle
      # stalls behind a defect that belongs to one story.
      #
      # Reads only issues carrying this `story_id`, so an issue in another
      # agent's territory cannot gate here. That is the same argument that
      # moved `issues_resolved` off `qa_setup`, applied one level down: a gate
      # whose passing state depends on work outside the gated unit is a wall.
      new!(%{
        id: 6,
        name: "story_issues_resolved",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.IssuesChecker, function: :story_resolved?},
        satisfied_by: AgentTasks.FixStoryIssues,
        artifact_type: :review,
        description:
          "Accepted issues QA filed against this story are resolved at the project's blocking severity",
        prerequisites: [4],
        execution_type: :main_agent
      }),
      # Criterion 1963: the loop's next work after QA clears is the UAT deploy.
      #
      # This node was removed in d207ad38 along with `devops_setup` and
      # `release`, because it gated on a markdown file the agent wrote for
      # itself and checked for the substring "verified". It reads
      # `CodeMySpec.Deploys` now — a row written when a deploy happens, whose
      # `health_verified_at` only a passing check sets. A story cannot satisfy
      # this by asserting it.
      #
      # UAT only. Prod promotion belongs to the release process, which is the
      # other half of the same criterion.
      #
      # Filtered out entirely when the project's `devops` setting is `:off`,
      # which is the default — see `maybe_filter_devops/2`. A project that does
      # not do infrastructure through this tool never sees the node.
      #
      # id 7, not 5. It shipped as 5, which `three_amigos_complete` already
      # held, and template ids are the only thing prerequisites resolve
      # through: `Map.new(template, &{&1.id, ...})` keeps the last writer, so
      # with devops on, `bdd_specs_exist`'s prerequisite [5] resolved to
      # `deploy` and closed a cycle through the whole story chain. Invisible
      # on the default `devops: :off`, where the filter drops `deploy` before
      # the map is built and 5 means what it reads as.
      new!(%{
        id: 7,
        name: "deploy",
        node_scope: :self,
        # The environment is config, not a function name. `uat_check/2` could
        # only ever answer for one environment, and environments are rows — a
        # project has whatever set it has. Naming it here means the same check
        # serves any of them.
        check_type: :deployed,
        config: %{environment: "uat"},
        satisfied_by: AgentTasks.Deploy,
        artifact_type: :deployment,
        description: "Story is deployed to UAT and its health check passed",
        prerequisites: [6],
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
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.PersonasChecker, function: :complete?},
        satisfied_by: AgentTasks.PersonaResearch,
        artifact_type: :specification,
        description:
          "At least one persona researched — DB record + summary.md + sources.md (story linkage happens later via Three Amigos)",
        # The root of this graph since `project_setup` left it. Setup is no
        # longer a requirement: `cms new` covers it, and the mainline exits the
        # generator with it complete, so a generated project has nothing to do.
        # Brownfield onboarding lives at /app/projects/:id/setup and is entered
        # deliberately — see `CodeMySpecWeb.ProjectSetupLive`.
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
        check_type: :delegate,
        config: %{module: AgentTasks.QaIntegrationPlan, function: :evaluate},
        satisfied_by: AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified, or no integrations are required",
        prerequisites: [3],
        validation_type: :manual
      }),
      new!(%{
        id: 5,
        name: "architecture_designed",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.ArchitectureChecker, function: :complete?},
        satisfied_by: AgentTasks.ArchitectureDesign,
        artifact_type: :specification,
        description:
          "Architecture proposal executed and every component is covered (story-linked, transitively depended on, or infrastructure)",
        prerequisites: [4]
      }),
      new!(%{
        id: 16,
        name: "spex_boundary_ready",
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.SpexBoundaryChecker, function: :complete?},
        satisfied_by: AgentTasks.SpexBoundaryReady,
        artifact_type: :specification,
        description:
          "BDD spec boundary protections installed — framework Credo checks + fixtures bridge + project BDD spec plan",
        prerequisites: [5]
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
        prerequisites: [16]
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
      # issues are *triaged*, not resolved.
      #
      # `qa_setup` is the seam the graph doc calls "the whole-project gate that
      # opens story-level work", so anything it waits on gates every story and
      # every component in the project. It used to wait on `issues_resolved`,
      # and the effect was that one open medium issue anywhere — in another
      # agent's territory, in a package awaiting a release, in something
      # instrumented and waiting to fire — held up designing and building
      # everything.
      #
      # Worse, it was unsatisfiable in the ordinary case: on a project several
      # agents share, no single agent can resolve every accepted issue, so the
      # gate had no passing state. Measured on this project: 19 accepted at
      # medium+, of which 7 belonged to other owners, 4 wanted an operator
      # publish and 3 were waiting for a failure to recur.
      #
      # Triage is the right gate here because triage is always satisfiable —
      # every issue can be accepted, dismissed or routed by whoever is looking
      # at it. A gate an agent cannot pass is not a gate, it is a wall.
      #
      # Resolution still gates, but at the end: see `qa_journey_plan`.
      new!(%{
        id: 14,
        name: "qa_setup",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/plan.md"},
        satisfied_by: AgentTasks.QaSetup,
        artifact_type: :review,
        description: "QA plan exists with App Overview, Tools Registry, and Seed Strategy",
        prerequisites: [6]
      }),
      # Where `issues_resolved` gates instead.
      #
      # The journey is the last thing before a release: it exercises the whole
      # app end to end, and running it against known-open defects tests a build
      # nobody intends to ship. So resolution belongs here, at the end, rather
      # than in front of the work that produces the thing being tested.
      #
      # This is also a fan-in — every story's `qa_complete` feeds it — so it is
      # already the node that means "the project is done except for the final
      # pass". Adding the issue queue to that is the same statement.
      new!(%{
        id: 10,
        name: "qa_journey_plan",
        node_scope: :self,
        check_type: :path_exists,
        config: %{path: ".code_my_spec/qa/journey_plan.md"},
        satisfied_by: AgentTasks.QaJourney,
        artifact_type: :review,
        description: "QA journey plan exists and valid",
        prerequisites: [14, 7]
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
        # Matches `Paths.qa_journey_wallaby_dir/0` and the QaJourney
        # task's @wallaby_dir. The requirement definition previously
        # had `test/e2e/` (legacy) which silently never matched what
        # the task actually writes.
        config: %{path_prefix: "test/journeys/"},
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
