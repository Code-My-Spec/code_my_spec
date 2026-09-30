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

  # Components describe implementation work. Test outcomes and acceptance
  # checks remain story requirements; markdown specs and reviews are inputs,
  # not additional work stages in the component graph.
  def context_graph do
    [
      implementation(9, :child, [], :develop_context),
      implementation(11, :parent, [9], :develop_context)
    ]
  end

  # A live context is a container: only its children have implementations.
  def live_context_graph do
    [implementation(9, :child, [], :develop_live_context)]
  end

  def default_graph, do: [implementation(5, :self)]
  def schema_graph, do: [implementation(3, :self)]
  def behaviour_graph, do: [implementation(3, :self)]
  def json_graph, do: [implementation(2, :self)]
  def controller_graph, do: [implementation(4, :self)]
  def liveview_graph, do: [implementation(5, :self)]

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
      # 56cf5697: sealing is a one-way latch on the conversation and correctly
      # ignores a question raised afterward (see the comment above), which
      # left a sealed story's post-seal open questions nothing's problem —
      # not blocking sealing (already past that), not offered to anyone
      # either, permanently. Gated on the seal itself (id 5) rather than
      # duplicating its pre-seal question gate: a story that has not sealed
      # yet already blocks sealing on the same open questions, so there is
      # nothing here for this node to do before that gate has cleared.
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
        # Per-criterion (issue 644279a9): a story with one spex file used to
        # read satisfied regardless of criterion count, so a criterion added
        # or reworded after the first pass got no spec and no work item.
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
      # Story 1003, added 2026-09-28: John — "I want all the problems gone,
      # all the issues fixed, then we run QA." Problems (compiler, credo,
      # exunit, spex findings) were previously only checked at promotion —
      # this closes the gap so QA is never spent on a copy the analyzers
      # already know is broken. Checks credo/compiler findings specifically
      # (`ProblemsChecker`, the same always-blocking half `Promotion`'s own
      # gate reads), scoped to this story's own working copy rather than
      # whichever copy happens to be asking. Narrower than promotion's full
      # definition of clean — see the module doc for why the rest of it
      # cannot be reused from here.
      new!(%{
        id: 19,
        name: "problems_resolved",
        role: :coding,
        node_scope: :self,
        check_type: :delegate,
        config: %{module: CodeMySpec.Requirements.ProblemsChecker, function: :resolved?},
        # No dedicated task exists for "clear analyzer findings generally" —
        # every existing coding task already surfaces persisted problems for
        # its own files via `ProblemFeedback`/the stop hook regardless of
        # which one is offered. `FixStoryIssues` is reused here as the
        # nearest "this story isn't release-ready yet" coding gate; its own
        # prompt is issue-specific and won't always describe *this* trigger
        # precisely when what's blocking is a bare compiler/credo finding
        # with no accepted issue behind it. Worth a dedicated task later if
        # that mismatch turns out to matter in practice.
        satisfied_by: AgentTasks.FixStoryIssues,
        artifact_type: :review,
        description: "This story's own working copy carries no blocking analyzer problem",
        prerequisites: [3],
        execution_type: :main_agent
      }),
      new!(%{
        id: 18,
        name: "story_promoted",
        role: :coding,
        node_scope: :self,
        # A question about state, not about an act. That is what lets an agent
        # working directly on the running copy satisfy it by arriving — there is
        # no branch to merge and nothing it could do to a gate phrased as "have
        # you promoted". John: "it is eminently possible that someone would be
        # just doing the work on Maine."
        check_type: :delegate,
        config: %{module: CodeMySpec.Promotion.RunningCopy, function: :running_copy_check},
        satisfied_by: AgentTasks.PromoteWork,
        artifact_type: :code,
        # f4786ba1: was `code_on_running_copy`, a name that read as a git fact.
        # An agent that verified ancestry, found the code on main, and concluded
        # the gate lied had answered a different question. Named for what it
        # reads: one column, `stories.promoted_version`, written only by a
        # `promote` that names this story.
        description:
          "This story carries a promotion stamp (`promoted_version`), written only " <>
            "by a promotion naming this story. Not a git check: code already on " <>
            "main does not satisfy it. Satisfy it by completing this task, which " <>
            "promotes the story.",
        # Story 1003, revised 2026-09-28: was [3], straight off
        # `bdd_specs_passing` — promotion used to be what QA tested. Now [4]:
        # story 1108 gave every working copy its own app, so QA tests the
        # story's own copy directly and no longer needs its code on the
        # checkout main runs from first. Promotion moves after QA instead —
        # it records that verified work landed, rather than being the thing
        # that makes the work testable.
        prerequisites: [4],
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
        #
        # Now [6] rather than [18]: known issues on the story are cleared before
        # QA spends a pass. John: "we have to move story issues resolved before
        # qa because that's the logical progression." The deadlock that forced
        # it is on `story_issues_resolved` below.
        #
        # Story 1003, revised 2026-09-28: `story_promoted` (18) is no
        # longer upstream of this node at all — it moved to *depend on*
        # `qa_complete` instead (story 1108 gave every copy its own app, so
        # QA no longer needs the story's code on main first). Added `19`
        # (`problems_resolved`) alongside the existing `6`: QA now waits on
        # both issues being clear and the copy's own analyzers being clean.
        #
        # Whether the story's own copy is actually serving is deliberately
        # *not* a prerequisite here (a `qa_target_serving` node ahead of this
        # one was tried and reverted the same day): `QaStory`'s own dispatch
        # already calls `AppTransport.ensure_app_running/2` live
        # (`qa_story.ex`'s `own_copy_app_url_line/1`) and, on anything short of
        # `"serving"`, still hands out the task with a prompt telling the agent
        # to say so and investigate rather than test. A graph-level refusal
        # that redirected to `PromoteWork` instead would have let an agent
        # stamp `promoted_version` before this node was ever satisfied — the
        # exact ordering story 1003 exists to prevent. Caught by Harness
        # before it shipped.
        #
        # `20` (`story_issues_triaged`): an untriaged finding on the story
        # holds QA too, at any severity (255f1dcd).
        prerequisites: [6, 19, 20],
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
      # Every finding on this story decided — accepted or dismissed — before QA
      # tests it again.
      #
      # metric_flow story 47, 2026-09-29: product triaged two highs and skipped
      # the low 9e8b52f4. `story_issues_resolved` counts only accepted issues at
      # the threshold, so QA was re-offered the story with a finding nobody had
      # looked at, and tapped out to a human (255f1dcd).
      #
      # Its own node rather than a second clause in `story_issues_resolved`,
      # because the work is product's: coding cannot accept or dismiss
      # (`Agents.ToolSets`), so offering it `FixStoryIssues` for an incoming
      # issue is the claim-find-nothing-tap-out spin.
      #
      # Off `component_linked`, the chain's head, so a finding can be triaged
      # whenever it lands; every story node descends from that head, and the
      # edge derivation relies on it. It gates only `qa_complete`, and product
      # has no work downstream of it, so it clamps nothing of product's own.
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
          "Accepted issues against this story are resolved at the project's blocking severity",
        # Was [4] — after `qa_complete`, on the reasoning that this gate is about
        # what a story's own QA pass raised. `IssuesChecker.story_resolved?/2`
        # does not read it that way: it counts *any* accepted issue carrying this
        # `story_id` at or above the threshold, whoever filed it and whenever.
        # Product files them, coding files them, and `Issues.attribute_to_story/3`
        # sweeps unattributed `:app` issues onto whichever story's QA attempt is
        # being submitted.
        #
        # So an issue could sit on a story before QA ever ran, block the QA
        # agent's task, and be unreachable — the node that clears it was gated
        # behind the QA it was preventing. Measured 2026-09-23 on Broken Oaths
        # story 947: QA's `qa_complete` task blocked on issue 71869489, and
        # `FixStoryIssues` could not be offered because `qa_complete` was its
        # prerequisite. Nothing in the graph broke the circle.
        #
        # The property the old order was protecting is not lost. "A story does
        # not release carrying a blocker its own QA pass raised" is enforced by
        # the checker, not by the ordering: this node is in
        # `StoryExecution.@completion_names`, so an issue QA files afterwards
        # takes the story back out of completion whenever it arrives. Ordering
        # only decides when the work is *offered*, and offering it before QA
        # spends a pass on a story with known blockers is the better trade.
        #
        # Story 1003, revised 2026-09-28: was [18] (`story_promoted`).
        # `story_promoted` moved to depend on `qa_complete`, which
        # depends on this node — leaving the prerequisite at [18] would have
        # closed a cycle (4 needs 6, 6 needs 18, 18 needs 4), the exact
        # deadlock shape this node exists to avoid. Repointed straight to [3]
        # (`bdd_specs_passing`): `IssuesChecker.story_resolved?/2` counts any
        # accepted issue regardless of ordering, so this only ever decided
        # *when* the work is offered, never enforced anything through the
        # edge itself — offering it as soon as specs are green is safe.
        prerequisites: [3],
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
        # Follows `qa_complete` rather than `story_issues_resolved`, which it
        # used to, because those two swapped places above. Deploy still comes
        # last in the story chain; the node it waits on is now the QA pass.
        #
        # Story 1003, revised 2026-09-28: was [4] (`qa_complete`) — no longer
        # enough on its own. `story_promoted` moved to depend on
        # `qa_complete` rather than the reverse, so staying on [4] would have
        # silently decoupled deploy from promotion: a story could clear QA
        # and be offered for UAT deploy before its code ever reached the
        # checkout main runs from. Repointed to [18] instead — deploy still
        # comes last, transitively through promotion and QA both.
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
        # The main agent's, and the line it draws is between the two
        # conversations this project has about a story. John: "the main agent
        # does the initial story interview that gets the initial stories up,
        # and then the product agent in the assigned working copy does the
        # three amigos".
        #
        # So `stories_exist` is main's and `three_amigos_complete` stays
        # product's. They read alike — both are multi-turn intake, both are
        # `validation_type: :manual` — and they are not the same work: the
        # first is project-scoped and happens before there is a checkout to
        # assign, and the second is per story on the copy that will build it.
        #
        # Tagged `:product` before, which left a project with no stories and no
        # product agent holding work that reached nobody. The main agent has
        # the conversation the person is actually in.
        role: :main,
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
  boundaries — coding owns `implementation_file` on a component and `bdd_specs_passing` on
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
