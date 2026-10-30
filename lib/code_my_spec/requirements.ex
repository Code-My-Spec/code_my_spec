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
      CodeMySpec.Analysis.HarnessRegistry,
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
      CodeMySpec.Qa,
      CodeMySpec.Qa.QaAttempt,
      CodeMySpec.Qa.Verdict,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      # `deploy` waits on `ProvisioningPlan.setup_missing/3`, the answer
      # `devops_status` reports.
      CodeMySpec.ProvisioningPlan,
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
  alias CodeMySpec.Requirements.CopyGraph
  alias CodeMySpec.Requirements.Directives
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.IncrementalGraph
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
  alias CodeMySpec.Requirements.StoryGraph
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
  across copies.
  """
  @spec placed_story_node(Scope.t(), atom() | nil, String.t(), term()) :: Requirement.t() | nil
  def placed_story_node(%Scope{} = scope, role, name, story_id) do
    with :project <- RoleProfile.story_vantage(role),
         true <- offered_to?(role, name),
         %{} = story <- Enum.find(Preloader.placed_elsewhere(scope), &same_id?(&1.id, story_id)) do
      {nodes, _edges} = CopyGraph.placed(scope, [story], [name])
      List.first(nodes)
    else
      _ -> nil
    end
  end

  defp same_id?(id, other), do: to_string(id) == to_string(other)

  @doc """
  Whether `node` is the work of story `story_id` at the scope's checkout —
  `StoryExecution.story_work?/3`, the set an agent bound to that story is
  offered and may claim.
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
  declared dependency closure, then selects the requirement nodes for them.
  Requirement edges never expand the component set. Other stories are excluded.

  Returns `{:ok, graph}` with `root_component`, selected `components`,
  `component_ids`, `component_edges` (dependent → dependency, including
  `provenance` and `in_code`), ownership-only `owners`, and the requirement
  `nodes`, `edges` (prerequisite → dependent), and `actionable` nodes.
  Authored dependencies absent from code are preserved, not silently discarded.
  An unlinked story has a nil root and no component work; an inaccessible story
  returns `{:error, :not_found}`. Reads the existing projection; no graph edits.
  """
  defdelegate story_graph(scope, story_id), to: StoryGraph, as: :read

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
  What is served against every entity recomputed from its inputs now — the check
  that the incremental graph is right. See `RequirementGraph.served_vs_recomputed/1`.
  Reports; changes nothing.
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
  Rebuild this checkout's graph from the domain now, and answer what is served.

  For "recompute now": a backfill, `sync_project`, a test establishing a graph.
  The projector forgets the vantage and seeds it whole; observations keep it
  current from there.
  """
  @spec recompute(Scope.t()) ::
          {{[Requirement.t()], [map()]}, [Requirement.t()], DateTime.t() | nil}
          | {:error, term()}
  def recompute(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    :ok = GraphStore.clear(scope)
    _ = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.reproject(project_id, Projection.vantage(scope))
    RequirementGraph.cached_graph_with_actionable(scope)
  end

  def recompute(%Scope{}), do: {:error, :no_project}

  @doc """
  Returns the next actionable requirements across the entire project,
  with cross-entity gates applied.
  """
  @spec next_actionable_project(Scope.t()) :: [Requirement.t()]
  def next_actionable_project(%Scope{} = scope) do
    RequirementGraph.next_actionable(scope)
  end

  @doc """
  The whole graph and its actionable set, read from the rows once the projector
  has settled, with the metrics the graph page shows about where the answer
  came from.

  `compute_graph_with_actionable_metrics/1` recomputes instead: it is the way to
  *time* a compute, and timing a read of the rows would measure nothing.

  The graph carries the components it was read with, dependencies preloaded,
  so a caller laying it out need not load them again.
  """
  @spec project_graph_with_actionable_metrics(Scope.t()) ::
          {%{
             nodes: [Requirement.t()],
             edges: [map()],
             actionable: [Requirement.t()],
             components: [map()]
           }, map()}
  def project_graph_with_actionable_metrics(%Scope{} = scope),
    do: RequirementGraph.cached_graph_with_actionable_metrics(scope)

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    RequirementGraph.compute_all(scope)
  end

  @doc """
  How many of a story's requirements are satisfied, at the scope's working copy.

  Counted over the same slice `story_graph/2` returns, so the cockpit's pie and
  the working copy status page's graph cannot disagree, but read from that
  slice's rows alone.
  """
  @spec story_progress(Scope.t(), integer()) :: {non_neg_integer(), non_neg_integer()}
  def story_progress(%Scope{} = scope, story_id) do
    case StoryGraph.read_progress(scope, story_id) do
      {:ok, progress} -> progress
      _ -> {0, 0}
    end
  end

  @doc """
  What `get_next_requirement` says about one task's requirement — the same
  directive the next-task page shows — or nil when the graph at the scope's
  copy no longer holds it. The task names its requirement and owner rather
  than a row id, so it is found by those.
  """
  @spec task_directive(Scope.t(), map()) :: String.t() | nil
  def task_directive(%Scope{} = scope, task) do
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    case Enum.filter(nodes, &task_on?(&1, task)) do
      [] -> nil
      found -> Directives.format_next_requirements(Directives.number_nodes(scope, found))
    end
  end

  @doc """
  Whether `task` is work on this requirement node: same requirement, same
  owner. A task names its requirement and owner rather than a row id.
  """
  @spec task_on?(map(), map()) :: boolean()
  def task_on?(%{name: name} = node, %{requirement_name: name} = task),
    do: owner_of(node) == owner_of(task)

  def task_on?(_node, _task), do: false

  @doc "What `get_next_requirement` says about one requirement node."
  @spec node_directive(Scope.t(), map()) :: String.t()
  def node_directive(%Scope{} = scope, node),
    do: Directives.format_next_requirements(Directives.number_nodes(scope, [node]))

  defp owner_of(%{entity_type: type, entity_id: id}), do: {type, to_string(id)}
  defp owner_of(%{issue_id: id}) when is_binary(id), do: {"issue", id}
  defp owner_of(%{story_id: id}) when not is_nil(id), do: {"story", to_string(id)}
  defp owner_of(%{component_id: id}) when is_binary(id), do: {"component", id}
  defp owner_of(%{project_id: id}), do: {"project", to_string(id)}

  @doc """
  Every requirement node, read from `requirements` and the project's edges
  (through `Requirements.Projection`) once the projector has applied what is
  pending, so it is current. `computed_at` says when the rows were written.
  """
  @spec cached_all(Scope.t()) :: {[map()], DateTime.t() | nil}
  def cached_all(%Scope{} = scope, opts \\ []) do
    {{nodes, _edges}, computed_at} = RequirementGraph.cached_graph(scope, opts)
    {nodes, computed_at}
  end

  @doc """
  Why a named requirement is still open, in the checker's own words.

  For the nudge: naming the node without the obstacle tells an agent *that*
  something is open and never *what* is holding it.

  `entity_ids` rather than one id because a task names its entity in whichever
  field fits — story, component or project — and the caller knows which of
  those it has.

  `""` when there is nothing to add: a node with no recorded reason, or one this
  scope cannot see, leaves the caller's message exactly as it was rather than
  appending an empty clause.

  Reads the one row and computes nothing: a stop is not a change.
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

  For readers that want the whole graph without recomputing it: a settle and a
  read of the rows, current as `cached_all/1` is.
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
  it stands rather than read from the graph. The graph can lag a
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
  The names of a story requirement's declared prerequisites that are not
  satisfied right now, read from the requirement definitions.

  A prerequisite that is not one of the story graph's own (a project-level one)
  is not judged here: this answers for the story's requirements, in the order
  they are declared. `[]` when every one is satisfied, or for a node that is
  not a story requirement.
  """
  @spec unmet_prerequisites(Scope.t(), Requirement.t() | map()) :: [String.t()]
  def unmet_prerequisites(%Scope{} = scope, %{entity_type: "story", name: name} = node) do
    definitions = RequirementDefinitionData.story_graph()

    case Enum.find(definitions, &(&1.name == name)) do
      nil ->
        []

      definition ->
        definitions
        |> Enum.filter(&(&1.id in definition.prerequisites))
        |> Enum.reject(&satisfied_now?(scope, %{node | name: &1.name}))
        |> Enum.map(& &1.name)
    end
  end

  def unmet_prerequisites(_scope, _node), do: []

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
