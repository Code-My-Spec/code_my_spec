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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :coding,
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
        role: :product,
        node_scope: :self,
        # Not `:field_present` on `component_id`. The migration computes a
        # component's id rather than looking it up — it is a pure function of the
        # project and the module name — so a story can carry a correct id for a
        # component the working copy has not synced yet. Presence would call that
        # linked; this asks whether the component is actually there, and becomes
        # satisfied on its own when the sync creates it.
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
        # Reads the seal rather than recomputing the conversation. A question
        # raised against a story that shipped months ago is the next
        # conversation, not evidence that the last one never happened — and
        # recomputing meant exactly that, silently.
        #
        # Automatic, because sealing already requires every rule to hold.
        # It was manual so the stop hook could not short-circuit the multi-turn
        # intake conversation, and the cost of that was severe: a session
        # holding a manual task is allowed out of `Hooks.Stop.do_decide/6`
        # before validation runs at all, so an open Three Amigos task switched
        # off spex, credo and exunit for that whole session. The short-circuit
        # cannot happen now for the reason it never could for a real
        # conversation: `ThreeAmigos.evaluate/2` completes only when persona,
        # rules, scenarios and zero open questions all hold, and no stop hook
        # can conjure those.
        validation_type: :automatic
      }),
      new!(%{
        id: 2,
        name: "bdd_specs_exist",
        role: :coding,
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
        role: :coding,
        node_scope: :self,
        # Was `:field_true` on `:specs_ready` alone. The field is still the
        # latch; the delegate adds the one thing a bare field read cannot do —
        # notice the latch was set by a gate that could not find the story's
        # specs and mistook that for their passing. See `SpecsPassingChecker`.
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.SpecsPassingChecker, function: :passing?},
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
        id: 18,
        name: "code_on_running_copy",
        role: :coding,
        node_scope: :self,
        # A question about state, not about an act. That is what lets an agent
        # working directly on the running copy satisfy it by arriving — there is
        # no branch to merge and nothing it could do to a gate phrased as "have
        # you promoted". John: "it is eminently possible that someone would be
        # just doing the work on Maine."
        check_type: :delegate,
        config: %{module: CodeMySpec.Promotion, function: :running_copy_check},
        satisfied_by: AgentTasks.PromoteWork,
        artifact_type: :code,
        # Named for the state QA depends on rather than for the merge, because
        # the merge is one way to reach it and not the only one.
        description: "Story's code is on the checkout the application runs from",
        prerequisites: [3],
        execution_type: :main_agent
      }),
      new!(%{
        id: 4,
        name: "qa_complete",
        role: :qa,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Qa, function: :complete_check},
        satisfied_by: AgentTasks.QaStory,
        artifact_type: :review,
        description: "QA complete: the latest DB-backed attempt is a valid pass",
        # Was [3] — straight off `bdd_specs_passing`. That is what let nine
        # stories reach QA on 2026-09-09 whose code had never left the coding
        # agent's worktree; QA failed all nine for code that was never there.
        prerequisites: [18],
        execution_type: :sub_agent,
        # Automatic, because "the latest DB-backed attempt is a valid pass"
        # is a query. `QaStory.evaluate/2` asks `Qa.qa_complete?/2` first and
        # completes on a real attempt, so nothing here needs a human to say it
        # is done.
        #
        # This was `:manual` for a real reason and it is worth recording why the
        # reason is gone. `execution_type: :sub_agent` says a sub-agent does the
        # work, `Session.active_task/1` selects by status with no reference to
        # `agent_id`, and the evaluator's only two answers were `:valid`, which
        # completes, and `:invalid`, which files feedback against the parent. So
        # the parent's own stop completed the QA sub-agent's live task before
        # any attempt existed, discarding the run (7f79b855). Marking it manual
        # stopped that.
        #
        # It also stopped everything else. A session holding a manual task is
        # allowed out of `Hooks.Stop.do_decide/6` *before* validation runs, so
        # for as long as a QA task was open no spex, credo or exunit finding
        # could block anybody. Measured 2026-08-28: 44 of 55 main stops on this
        # machine skipped the gate entirely, across two sessions, and the agents
        # were never told they held the task that was doing it.
        #
        # The honest fix was the answer the guard always needed — `:skip`, which
        # leaves a sub-agent's task active instead of completing or failing it.
        # With that in `TaskEvaluator`, automatic is safe: a premature
        # completion is impossible because completing requires the attempt.
        validation_type: :automatic
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
        role: :coding,
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
        role: :main,
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
        role: :product,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.PersonasChecker, function: :complete?},
        satisfied_by: AgentTasks.PersonaResearch,
        artifact_type: :specification,
        description:
          "Every persona researched — DB record + summary.md + sources.md (story linkage happens later via Three Amigos)",
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
        role: :product,
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
        role: :main,
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
      # Unsatisfied only when nothing is in progress and unassigned work exists
      # — the one state that wants the main agent to act. It never assigns
      # anything itself: John kept sending and approving as two acts.
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
        role: :qa,
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
        role: :qa,
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
        role: :qa,
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
        role: :qa,
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

  @doc """
  Every requirement name belonging to one role.

  Story 538's R10 asks "is there work of my kind" on every stop, and the answer
  is a set of names: the role lives on the definition and the requirements read
  model has no column for it, so `NodeRepository` narrows its count by name
  rather than by a join.

  Read across every graph, because a role's work does not respect entity
  boundaries — coding owns `spec_file` on a component and `bdd_specs_passing` on
  a story, and an agent that only counted one of those would go home with the
  other outstanding.

  Deduplicated: the same name appears in several component graphs with the same
  role, and a duplicate in an `IN` clause is noise the database has to think
  about.
  """
  @spec requirement_names_for_role(atom()) :: [String.t()]
  def requirement_names_for_role(role) when is_atom(role) do
    all_graphs()
    |> Enum.filter(&(&1.role == role))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

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
