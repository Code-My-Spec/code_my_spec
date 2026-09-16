defmodule CodeMySpec.Requirements do
  @moduledoc """
  Public API for the requirements graph.

  Requirements are computed on the fly from Files + Problems — not persisted.
  Three entity levels: component, story, project. The graph treats all nodes
  uniformly; cross-entity gates affect actionability but aren't edges.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.BddRules,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Deploys,
      CodeMySpec.EpicDispatch,
      CodeMySpec.Faults,
      CodeMySpec.Files,
      CodeMySpec.Issues,
      CodeMySpec.Paths,
      CodeMySpec.Personas,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      # Mutual with `Promotion`, which gates on the graph before it merges, the
      # same shape `Deploys` already has here. `code_on_running_copy` is
      # Promotion's verdict, and a graph that decided it for itself would be a
      # second answer to the question promotion exists to answer.
      CodeMySpec.Promotion,
      CodeMySpec.Qa,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.IncrementalReport
  alias CodeMySpec.Requirements.NodeRepository
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @doc """
  How many requirements this role can act on, from a graph known to be current.

  One definition of "your work", shared with `get_next_requirement`. They used
  to have two: the tool computed the graph, and the stop menu counted
  `requirements` rows directly — so the menu could advertise work that had
  already been done, send the agent to ask for it, and be told there was none.
  Watched on 2026-09-07: "27 requirements — `get_next_requirement`" against
  "All requirements satisfied", once every six seconds until the rows caught up.

  The menu read rows raw to avoid a recompute, on a hazard note in
  `Validation.Menu` saying `next_actionable/1` "globs the working copy" and
  would deadlock the stop decision inside the channel process. That was true and
  is not: `DelegateFiles` used to hash working-copy files off disk, and
  `RequirementGraph` records that classify claims those files now, so
  `files_digest` covers them by content hash "and the side channel is gone". The
  preloader is `Repo.all/1`. A recompute is ~170ms of database.

  So this goes through `cached_graph_with_actionable/1` like every other reader:
  fingerprint hit serves the published graph, miss recomputes and republishes.
  Nothing here can be stale, which is the property the count needs and the one
  reading rows could not give it.

  `nil` role counts everything actionable, which is what a caller outside the
  loop wants.
  """
  @spec actionable_count(Scope.t(), atom() | nil) :: non_neg_integer()
  def actionable_count(%Scope{active_project_id: nil}, _role), do: 0

  def actionable_count(%Scope{} = scope, role),
    do: scope |> actionable_for_role(role) |> length()

  @doc """
  The actionable requirements this role can act on, in graph order.

  The list `actionable_count/2` counts, so a caller that wants to *say* what
  the work is reads the same answer the count came from rather than asking a
  second question that can disagree with it — the failure this module's own
  comments record twice over.

  `nil` role answers the project's, which is what every caller outside the loop
  wants.
  """
  @spec actionable_for_role(Scope.t(), atom() | nil) :: [map()]
  def actionable_for_role(%Scope{active_project_id: nil}, _role), do: []

  def actionable_for_role(%Scope{} = scope, role) do
    # Settle first. A pending recompute means a write has landed that this count
    # has not seen, and this count is what decides whether an agent is told to
    # stop — deciding a beat before the recompute means deciding from the older
    # answer. `:ok` when nothing is pending and when nobody is watching.
    GraphWatcher.settle(scope)

    {_graph, actionable, _computed_at} = RequirementGraph.cached_graph_with_actionable(scope)

    case role && RequirementsRegistry.requirement_names_for_role(role) do
      nil -> actionable
      [] -> []
      names -> Enum.filter(actionable, &(&1.name in names))
    end
  end

  @doc """
  Which entities read stale right now — the expensive diff, run deliberately.

  See `RequirementGraph.stale_entities_report/1`. Reports; changes nothing.
  """
  @spec stale_entities_report(Scope.t()) ::
          {:partial, [{String.t(), term()}]} | {:all, String.t()} | {:error, term()}
  def stale_entities_report(%Scope{} = scope), do: RequirementGraph.stale_entities_report(scope)

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
  def cached_all(%Scope{} = scope) do
    {{nodes, _edges}, computed_at} = RequirementGraph.cached_graph(scope)
    {nodes, computed_at}
  end

  @doc """
  Why a named requirement is still open, in the checker's own words.

  For the nudge. Naming the node without the obstacle makes the message
  unactionable by construction — an agent is told *that* something is open and
  never *what* is holding it. Watched live on 2026-09-10: a coding agent nudged
  every 90 seconds about `code_on_running_copy` while the gate was refusing on
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
