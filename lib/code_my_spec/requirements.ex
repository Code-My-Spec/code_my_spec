defmodule CodeMySpec.Requirements do
  @moduledoc """
  Public API for the requirements graph.

  Requirements are computed from Files and the project's records.
  Three entity levels: component, story, project. The graph treats all nodes
  uniformly; cross-entity gates affect actionability but aren't edges.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Stories,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.BddRules,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Deploys,
      CodeMySpec.Epics,
      CodeMySpec.Faults,
      CodeMySpec.Files,
      CodeMySpec.Issues,
      CodeMySpec.Paths,
      CodeMySpec.Personas,
      CodeMySpec.Projects,
      # `story_promoted` is Promotion's verdict, and a graph that decided
      # it for itself would be a second answer to the question promotion exists
      # to answer. So the graph reads it — from this leaf, not from `Promotion`,
      # which sits above the graph and must not be called by it.
      CodeMySpec.Promotion.RunningCopy,
      CodeMySpec.Qa.QaAttempt,
      CodeMySpec.Qa.Verdict,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      # `deploy` waits on `Resources.setup_missing/3`, the answer
      # `devops_status` reports.
      CodeMySpec.Resources,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Requirements.Invalidation,
      CodeMySpec.Requirements.Invalidations,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files
  alias CodeMySpec.Requirements.BacklogReport
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.IncrementalReport
  alias CodeMySpec.Requirements.NodeRepository
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.StoryExecution
  alias CodeMySpec.Requirements.VantageReport
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  The current story's execution state; never falls back to project work.

  `withheld?` drops nodes the caller cannot claim, before the wave is cut.
  `assignment` is whose story: `:copy` (the copy's team's story),
  `{:team, story_id, epic_id}`, `{:bound, story_id, epic_id}` (an agent bound
  to its active story, offered nothing outside it) or `:project`.
  """
  def story_execution(
        scope,
        role \\ nil,
        requested_number \\ nil,
        withheld? \\ fn _ -> false end,
        assignment \\ :copy
      ),
      do: StoryExecution.read(scope, role, requested_number, withheld?, assignment)

  @doc """
  How many requirements this role can act on for this working copy, before any
  agent's claims. An agent's work — what it is offered, counted and told — is
  `Agents.Work.work_for/4`, which adds its checkout and what it may not claim.

  `story_execution/3` is the graph's definition. With a story selected it is that
  story's work; without one it is the project's requirements plus whatever
  stories are assigned to this copy. That fallback is what keeps project-level
  work — `issues_triaged`, `architecture_designed`, the QA journey — reaching
  the agent who can do it, which is story 1005's rule.
  """
  @spec actionable_count(Scope.t(), atom() | nil) :: non_neg_integer()
  def actionable_count(%Scope{active_project_id: nil}, _role), do: 0
  def actionable_count(%Scope{} = scope, role), do: length(actionable_for_role(scope, role))

  @doc """
  The actionable requirements this role can act on, in graph order — the list
  `actionable_count/2` counts, so a caller that wants to *say* what the work is
  reads the same answer the count came from.
  """
  @spec actionable_for_role(Scope.t(), atom() | nil) :: [map()]
  def actionable_for_role(%Scope{active_project_id: nil}, _role), do: []
  def actionable_for_role(%Scope{} = scope, role), do: story_execution(scope, role).actionable

  @doc """
  The node `name` on a story placed on another copy, read at that copy, when
  `role` reads every story wherever it is placed and `name` is its own work;
  `nil` otherwise. `start_task`'s lookup for what `story_execution/5` offers
  across copies (a31f1cd6 step 4d).
  """
  @spec placed_story_node(Scope.t(), atom() | nil, String.t(), term()) :: Requirement.t() | nil
  def placed_story_node(%Scope{} = scope, role, name, story_id) do
    with :project <- RoleProfile.story_vantage(role),
         true <- offered_to?(role, name),
         %{} = story <- Enum.find(Preloader.placed_elsewhere(scope), &same_id?(&1.id, story_id)) do
      {nodes, _edges} = Projection.placed([story], [name])
      List.first(nodes)
    else
      _ -> nil
    end
  end

  defp same_id?(id, other), do: to_string(id) == to_string(other)

  @doc """
  Whether `node` is the work of story `story_id` at the scope's checkout —
  `StoryExecution.story_work?/3`, the set an agent bound to that story is
  offered and may claim (4292518a).
  """
  @spec story_work?(Scope.t(), term(), map()) :: boolean()
  def story_work?(%Scope{} = scope, story_id, node) do
    with %{} = story <- Stories.get_story(scope, story_id),
         {:ok, ctx} <- Preloader.load(scope) do
      StoryExecution.story_work?(story, node, ctx)
    else
      _ -> false
    end
  end

  @doc """
  A story's architecture and requirements at the scope's working copy.

  Starts at the story's linked component, follows its component subtree and
  declared dependency closure, then selects the published requirement nodes.
  Requirement edges never expand the component set. Other stories are excluded.

  Returns `{:ok, graph}` with `root_component`, selected `components`,
  `component_ids`, `component_edges` (dependent → dependency, including
  `provenance` and `in_code`), ownership-only `owners`, and the requirement
  `nodes`, `edges` (prerequisite → dependent), and `actionable` nodes.
  Authored dependencies absent from code are preserved, not silently discarded.
  An unlinked story has a nil root and no component work; an inaccessible story
  returns `{:error, :not_found}`. Reads the existing projection; no graph edits.
  """
  defdelegate story_graph(scope, story_id), to: CodeMySpec.Requirements.StoryGraph, as: :read

  @doc "Adds live project-issue branches to the requirements graph visualization."
  defdelegate issue_bag_graph(issues), to: CodeMySpec.Requirements.ProjectIssueGraph, as: :bag

  defdelegate project_issue_graph(scope, graph),
    to: CodeMySpec.Requirements.ProjectIssueGraph,
    as: :read

  @doc """
  Whether requirement `name` is one `role` is offered, by its profile's
  `requirements` selectors — the filter `actionable_for_role/2` applies.
  """
  @spec offered_to?(atom(), String.t()) :: boolean()
  def offered_to?(role, name) when is_atom(role) and is_binary(name),
    do: name in RequirementsRegistry.requirement_names_for_role(role)

  @doc """
  Which entities read stale right now — the expensive diff, run deliberately.

  See `RequirementGraph.stale_entities_report/1`. Reports; changes nothing.
  """
  @spec stale_entities_report(Scope.t()) ::
          {:partial, [{String.t(), term()}]} | {:all, String.t()} | {:error, term()}
  def stale_entities_report(%Scope{} = scope), do: RequirementGraph.stale_entities_report(scope)

  @doc """
  What is served against every entity recomputed from its inputs now — the
  instrument for the event path, which stamps no fingerprint. See
  `RequirementGraph.served_vs_recomputed/1`. Reports; changes nothing.
  """
  @spec served_vs_recomputed(Scope.t()) :: map()
  def served_vs_recomputed(%Scope{} = scope), do: RequirementGraph.served_vs_recomputed(scope)

  @doc "Whether any vantage of this project has ever been projected: its project rows exist."
  @spec projected?(Scope.t()) :: boolean()
  def projected?(%Scope{} = scope), do: RequirementGraph.projected?(scope)

  @doc """
  What the rows say about whether the graph recomputes incrementally.

  Read-only, and from the rows rather than from a log: every pass stamps
  `checked_at` on exactly the entities it recomputed, so the size of each
  distinct stamp is the size of a pass. See `Requirements.IncrementalReport`.
  """
  @spec incremental_report(Scope.t(), keyword()) :: map()
  def incremental_report(%Scope{} = scope, opts \\ []),
    do: IncrementalReport.build(scope, opts)

  @doc """
  What each checkout's graph looks like right now, side by side.

  A verdict is a statement about one checkout, so the graph is ten parallel
  answers rather than one — and both routing bugs found on 2026-09-17 were
  invisible from any single vantage. See `Requirements.VantageReport`.
  """
  @spec vantage_report(Scope.t()) :: [map()]
  def vantage_report(%Scope{} = scope), do: VantageReport.build(scope)

  @doc """
  Marks written and not yet applied, grouped by who wrote them.

  A growing total means drains are failing or falling behind; a flat non-zero
  one means the same thing more quietly. See `Requirements.BacklogReport`.
  """
  @spec backlog_report(Scope.t()) :: map()
  def backlog_report(%Scope{} = scope), do: BacklogReport.build(scope)

  @doc """
  Every declared event kind, and whether anything can apply it.

  The vocabulary is a closed list on purpose — `GraphInputs.event/6` refuses a
  kind that is not in it — so "what can move the graph" is answerable, and this
  is the answer plus what each kind currently costs.

  A kind that falls back is not a defect. Handlers arrive one at a time and the
  projection is correct in the meantime, only slower: an unhandled event still
  names its entities and is recomputed from them. What would be a defect is a
  kind falling back and nobody knowing, because that is a full recompute on
  every occurrence wearing the same label as an applied one.

  So the debt is a list rather than a silence, and it is published rather than
  living only in a test, because the thing it describes changes whenever a
  writer or a handler is added.
  """

  @spec event_vocabulary() :: [%{kind: String.t(), applied: boolean()}]
  def event_vocabulary do
    handled = MapSet.new(Handlers.handled_kinds())

    Enum.map(GraphInputs.kinds(), fn kind ->
      %{kind: kind, applied: MapSet.member?(handled, kind)}
    end)
  end

  @doc """
  The refusals the writer API makes, asked rather than triggered.

  Two guarantees hold the vocabulary closed and the routing honest: a kind that
  was never declared cannot be emitted, and a writer that does not say whose
  answers it moves is refused rather than given a default. Both were enforced
  only by raising, which made them demonstrable only by attempting the thing
  they exist to prevent — so neither was visible anywhere.

  `GraphInputs.check/2` is the same check `event/6` applies, so this reports the
  live rule rather than a description of it. Each entry is `refused?` plus the
  explanation a writer would have been given.
  """
  @spec emit_guarantees() :: [
          %{claim: String.t(), probe: String.t(), refused?: boolean(), because: String.t() | nil}
        ]
  def emit_guarantees do
    [
      {"An event the graph has no vocabulary for is refused", "a kind nobody declared",
       GraphInputs.check("a_kind_nobody_declared", :project_wide)},
      {"A writer that does not say whose answers it moves is refused",
       "a declared kind, with no vantage",
       GraphInputs.check(List.first(GraphInputs.kinds()), nil)}
    ]
    |> Enum.map(fn {claim, probe, result} ->
      %{claim: claim, probe: probe, refused?: result != :ok, because: because(result)}
    end)
  end

  defp because({:error, message}), do: message |> String.split("\n") |> List.first()
  defp because(:ok), do: nil

  @doc """
  Which row-space answered this scope, and whose tree those rows are about.

  Two different facts, and a reader that names no checkout is the case where
  they differ: it is answered from the rows kept under no working copy, and
  those rows were computed from the project's **main** checkout's files.
  Collapsing them is how a checkout's own answers get served as though they
  were the project's.

  Unobservable from outside until now, which made the distinction unassertable:
  the graph carried the answers and nothing saying what they were an answer
  *about*.
  """
  @spec vantage_of(Scope.t()) :: %{rows: Ecto.UUID.t() | nil, files: Ecto.UUID.t() | nil}
  def vantage_of(%Scope{} = scope),
    do: %{rows: Projection.vantage(scope), files: Preloader.files_copy(scope)}

  @doc """
  Bring this project's rows up to date, and answer from the work just done.

  The write path's entry point, and the only thing that writes requirement
  rows. `GraphWatcher` calls it when observations land; everything else reads.

  Public because "recompute now" is a real operation a caller outside the
  watcher sometimes needs — a test establishing a graph to read, a backfill, an
  operator on a project whose watcher died. It is not a repair a reader should
  reach for: a read that recomputes is what made a writer that announces
  nothing indistinguishable from one that works.
  """
  @spec recompute(Scope.t()) ::
          {{[Requirement.t()], [map()]}, [Requirement.t()], NaiveDateTime.t() | nil}
          | {:error, term()}
  def recompute(%Scope{} = scope), do: RequirementGraph.recompute(scope)

  @doc """
  Returns the next actionable requirements across the entire project,
  with cross-entity gates applied.
  """
  @spec next_actionable_project(Scope.t()) :: [Requirement.t()]
  def next_actionable_project(%Scope{} = scope) do
    RequirementGraph.next_actionable(scope)
  end

  @doc """
  Returns the full computed requirements graph plus the next actionable
  requirements, computed in a single pass.

  > #### Prefer `cached_graph_with_actionable/1` {: .warning}
  >
  > This recomputes every node and edge — 4.4 seconds against 34ms of preload on
  > a 3200-component project — and no caller needs that. The graph is a read
  > model now (`requirements`, `requirement_edges`), and the cached form recomputes
  > on a fingerprint miss, so it is never stale.
  >
  > Nothing calls this. It is kept because `project_graph_with_actionable_metrics/1`
  > exists to *time* a compute, and a timing function that read a cache would
  > measure nothing.
  """
  @spec project_graph_with_actionable(Scope.t()) ::
          %{nodes: [Requirement.t()], edges: [map()], actionable: [Requirement.t()]}
  def project_graph_with_actionable(%Scope{} = scope) do
    {nodes, edges, actionable} = RequirementGraph.compute_graph_with_actionable(scope)
    %{nodes: nodes, edges: edges, actionable: actionable}
  end

  @doc """
  Same as `project_graph_with_actionable/1`, from the cache, with provenance.

  Serves the published graph when the fingerprint hits and recomputes when it
  misses, so this is never stale — `metrics.computed_at` says when the answer
  was made and `metrics.served_from` says which of the two happened.

  It recomputed unconditionally until 2026-09-11, which made the requirements
  graph page the only reader of the graph that never used the cache: 4.4 seconds
  against 34ms of preload, on every visit, while stories 1062 and 1063 were
  being written to make the cached answer trustworthy. The page also had no
  freshness to show, because it had no cached answer to be fresh or stale.

  `compute_graph_with_actionable_metrics/1` still exists and still recomputes —
  it is the one honest way to *time* a compute, and a timing function that read
  a cache would measure nothing.
  """
  @spec project_graph_with_actionable_metrics(Scope.t()) ::
          {%{nodes: [Requirement.t()], edges: [map()], actionable: [Requirement.t()]}, map()}
  def project_graph_with_actionable_metrics(%Scope{} = scope) do
    {{nodes, edges, actionable}, metrics} =
      RequirementGraph.cached_graph_with_actionable_metrics(scope)

    {%{nodes: nodes, edges: edges, actionable: actionable}, metrics}
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    RequirementGraph.compute_all(scope)
  end

  @doc "How many of a story's requirements are satisfied, at one working copy."
  @spec story_progress(integer(), Ecto.UUID.t() | nil) :: {non_neg_integer(), non_neg_integer()}
  defdelegate story_progress(story_id, working_copy_id), to: NodeRepository

  @doc """
  Every requirement node, read from the projection when it is still current.

  The caveat that used to be here — "not for deciding what an agent works on" —
  was written when the fingerprint watched only files, components and stories,
  so a hit could not certify what the delegate checkers read. It watches all of
  them now, one test per input in `graph_cache_test.exs`, and
  `compute_and_publish/3` says so in as many words. A hit is as good as a
  recompute.

  What it returns is the read model: `requirements` and `requirement_edges`,
  through `Requirements.Projection`. A miss recomputes and republishes, so this
  is never stale — `computed_at` says when, and `nil` means just now.
  """
  @spec cached_all(Scope.t()) :: {[map()], DateTime.t() | nil}
  def cached_all(%Scope{} = scope, opts \\ []) do
    {{nodes, _edges}, computed_at} = RequirementGraph.cached_graph(scope, opts)
    {nodes, computed_at}
  end

  @doc """
  Why a named requirement is still open, in the checker's own words.

  For the nudge. Naming the node without the obstacle makes the message
  unactionable by construction — an agent is told *that* something is open and
  never *what* is holding it. Watched live on 2026-09-10: a coding agent nudged
  every 90 seconds about `story_promoted` while the gate was refusing on
  "uncommitted changes — commit them", a sentence the checker had already
  written and the nudge threw away.

  `entity_ids` rather than one id because a task names its entity in whichever
  field fits — story, component or project — and the caller knows which of
  those it has.

  `""` when there is nothing to add: a node with no recorded reason, or one this
  scope cannot see, leaves the caller's message exactly as it was rather than
  appending an empty clause.

  Reads the one row, and computes nothing.

  It used to read `cached_all/1`, whose docstring calls itself cheap — "34ms of
  preload against 4.4 seconds of recompute". That is the hit. The stop hook,
  which is this function's only caller, syncs files before it decides, so the
  graph fingerprint has always just moved and the miss is the normal case: the
  whole project rebuilt, edges included, to read one string the row already
  holds. Measured on the running build, four full computes in nine minutes, two
  of them stop hooks.

  A stop is not a change, so nothing here recomputes.
  """
  @spec open_reason(Scope.t(), String.t() | nil, [String.t()]) :: String.t()
  def open_reason(scope, requirement_name, entity_ids)

  def open_reason(_scope, nil, _entity_ids), do: ""

  def open_reason(%Scope{} = scope, requirement_name, entity_ids) do
    scope
    |> NodeRepository.requirement_details(requirement_name, entity_ids)
    |> reason_of()
  end

  defp reason_of(details) when is_map(details) do
    case Map.get(Requirement.normalize_details(details), "reason") do
      reason when is_binary(reason) and reason != "" -> reason
      _ -> ""
    end
  end

  defp reason_of(_details), do: ""

  @doc """
  Nodes, edges and the actionable set, from the read model.

  The cached counterpart to `project_graph_with_actionable/1`, for readers that
  want the whole graph without paying to recompute it — which on a
  3200-component project is 4.4 seconds against 34ms of preload.

  Same certification as `cached_all/1`: a miss recomputes and republishes, so
  this is never stale.
  """
  @spec cached_graph_with_actionable(Scope.t()) ::
          %{nodes: [Requirement.t()], edges: [map()], actionable: [Requirement.t()]}
  def cached_graph_with_actionable(%Scope{} = scope) do
    {{nodes, edges}, actionable, _computed_at} =
      RequirementGraph.cached_graph_with_actionable(scope)

    %{nodes: nodes, edges: edges, actionable: actionable}
  end

  @doc """
  Whether a story requirement is satisfied *now*, computed from the story as
  it stands rather than read from the graph (67e6b5cb). The graph can lag a
  write that did not announce, and then goes on offering work already done;
  `start_task` asks this before taking it. Story requirements only, where the
  stale offers were: anything else answers false, because a satisfied
  component or project requirement is sometimes started on purpose.
  """
  @spec satisfied_now?(Scope.t(), Requirement.t() | map()) :: boolean()
  def satisfied_now?(%Scope{} = scope, %{entity_type: "story", entity_id: id, name: name}) do
    story_id = if is_binary(id), do: String.to_integer(id), else: id

    with {:ok, %{stories: [story]} = ctx} <- Preloader.load_story(scope, story_id),
         %{} = definition <-
           Enum.find(RequirementDefinitionData.story_graph(), &(&1.name == name)) do
      files = Map.get(ctx.files_by_story, story.id, [])
      RequirementCalculator.compute_one(scope, story, definition, files, ctx).satisfied == true
    else
      _ -> false
    end
  end

  def satisfied_now?(_scope, _node), do: false

  @doc """
  Tell the graph an entity moved: a requirement found satisfied on a fresh
  check, so the stale offer clears on the next pass.
  """
  @spec refresh_entity(Scope.t(), {String.t(), term()}) :: :ok
  def refresh_entity(%Scope{} = scope, {"story", id}),
    do: GraphInputs.announce(scope, "Requirements", [{"story", id}], :project_wide)

  # --- Legacy shims (TODO: move evaluation criteria onto agent tasks) ---

  @doc """
  Compute all requirements for a component with satisfaction status.
  Returns a list of maps with requirement definition fields plus `:satisfied`.
  """
  def compute_component_requirements(scope, %Component{} = component) do
    definitions = RequirementsRegistry.get_requirements_for_type(component.type)
    files = Files.list_component_files(scope, component.id)

    Enum.map(definitions, fn definition ->
      result = RequirementCalculator.compute_one(scope, component, definition, files)
      Map.merge(result, Map.from_struct(definition))
    end)
  end

  @doc """
  Check component requirements filtered by artifact_type.
  Bridges old agent task evaluate functions to the computed model.
  """
  def check_artifact_requirements(scope, %Component{} = component, artifact_type) do
    scope
    |> compute_component_requirements(component)
    |> Enum.filter(&(&1.artifact_type == artifact_type))
  end

  @doc "Filters `requirements` by name/exclude/artifact-type opts."
  def check_requirements(_scope, _entity, requirements, opts) when is_list(requirements) do
    include_types = Keyword.get(opts, :include, [])
    exclude_types = Keyword.get(opts, :exclude, [])
    artifact_types = Keyword.get(opts, :artifact_types, [])

    requirements
    |> Enum.filter(fn req ->
      name = req[:name] || Map.get(req, :name)
      artifact = req[:artifact_type] || Map.get(req, :artifact_type)

      exclude = exclude_types != [] and name in exclude_types
      include = include_types == [] or name in include_types
      artifact_match = artifact_types == [] or artifact in artifact_types

      include and not exclude and artifact_match
    end)
  end

  @doc "No-op. Called from `files_live.ex` on project reset; nothing here needs clearing."
  def clear_all_project_requirements(_scope), do: :ok
end
