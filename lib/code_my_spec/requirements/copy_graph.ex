defmodule CodeMySpec.Requirements.CopyGraph do
  @moduledoc """
  A checkout's graph, read from what is kept once per project and what its
  harness reported: nothing is stored per checkout.

  Nodes are the templates' for the entities the reader sees
  (`RequirementGraph.defined_nodes/3`). Each verdict comes from the project's
  record verdicts (`project_requirements`), the copy's overlay (its file
  verdicts, `CopyOverlay`), or its three placement gates, settled on read
  (`Handlers.gate_verdicts/1`). Edges are the project's among those nodes.

  Served: every reader reads it. The per-copy projection is still written
  until its deletion, so the switch reverts with no data change.
  See knowledge/requirements_graph/overlay.md.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Configurations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CopyOverlay
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @no_checkout "no checkout has reported files"
  @awaiting "awaiting this copy's report"

  @doc "The graph at the scope's vantage, as `{nodes, edges}`."
  @spec load(Scope.t(), map()) :: {[Requirement.t()], [map()]}
  def load(%Scope{} = scope, ctx) do
    # A project never projected, or a checkout it does not have, reads as no
    # graph rather than half of one.
    if projected_at?(scope), do: read(scope, ctx), else: {[], []}
  end

  defp projected_at?(%Scope{active_project_id: project_id, active_working_copy_id: nil}),
    do: not is_nil(GraphStore.topology(project_id))

  defp projected_at?(%Scope{active_project_id: project_id, active_working_copy_id: copy} = scope),
    do:
      projected_at?(%{scope | active_working_copy_id: nil}) and
        Repo.exists?(
          from(w in CodeMySpec.WorkingCopies.WorkingCopy,
            where: w.id == ^copy and w.project_id == ^project_id
          )
        )

  defp read(%Scope{active_project_id: project_id} = scope, ctx) do
    scope = RequirementGraph.with_project(scope)
    config = Configurations.get_or_create(scope)
    defined = RequirementGraph.defined_nodes(ctx, config, project_id)
    copy_names = Handlers.copy_names()
    gate_names = Handlers.gate_names()

    {overlay, checked_at} = overlay(scope)
    gates = scope |> Handlers.gate_verdicts() |> Map.new(&{&1.name, sweep(&1)})

    reported =
      for identity <- defined, identity.name in copy_names or identity.name in gate_names do
        {satisfied, details} =
          verdict(if(identity.name in gate_names, do: gates, else: overlay), identity)

        row(identity, satisfied, details, checked_at)
      end

    nodes = Projection.rehydrate_all(record_rows(project_id, ctx) ++ reported, ctx)
    {nodes, Projection.edges_for(project_id, nodes)}
  end

  @doc """
  The details of a file verdict or placement gate `name` on the first of
  `entity_ids` it names, at the scope's vantage, without loading the graph.
  `nil` for any other name: those are rows (`NodeRepository`).
  """
  @spec details(Scope.t(), String.t(), [String.t()]) :: map() | nil | :not_reported
  def details(scope, name, entity_ids) do
    scope = RequirementGraph.with_project(scope)

    cond do
      name in Handlers.copy_names() ->
        {overlay, _checked_at} = overlay(scope)
        swept_details(overlay, name, entity_ids)

      name in Handlers.gate_names() ->
        gates = scope |> Handlers.gate_verdicts() |> Map.new(&{&1.name, sweep(&1)})
        swept_details(gates, name, entity_ids)

      true ->
        :not_reported
    end
  end

  defp swept_details(sweeps, name, entity_ids) do
    identities = Enum.map(entity_ids, &%{name: name, entity_id: &1})

    found =
      case sweeps do
        {:none, _reason} -> nil
        sweeps -> excepted(Map.get(sweeps, name), identities)
      end

    {_satisfied, details} = found || verdict(sweeps, %{name: name, entity_id: nil})
    details
  end

  # An exception names its entity by id, which a caller hands as a string.
  defp excepted(nil, _identities), do: nil

  defp excepted({_default, _details, except}, identities) do
    Enum.find_value(except, fn {id, verdict} ->
      if Enum.any?(identities, &(to_string(id) == to_string(&1.entity_id))), do: verdict
    end)
  end

  @doc """
  The nodes `names` of `stories` placed at other copies, each read at its own
  placement copy: for a reader whose role sees every story wherever it is
  placed (product). Record verdicts are the project's; a story's file verdict
  is its placement copy's. Edges are those among the nodes read.

  Every story must carry its `working_copy_id`.
  """
  @spec placed(Scope.t(), [map()], [String.t()]) :: {[Requirement.t()], [map()]}
  def placed(_scope, [], _names), do: {[], []}

  def placed(%Scope{active_project_id: project_id} = scope, stories, names) do
    scope = RequirementGraph.with_project(scope)
    copy_names = Handlers.copy_names()

    reported =
      for {copy, here} <- Enum.group_by(stories, & &1.working_copy_id),
          {overlay, checked_at} = overlay(%{scope | active_working_copy_id: copy}),
          story <- here,
          name <- names,
          name in copy_names do
        identity = %{
          entity_type: "story",
          entity_id: story.id,
          name: name,
          owner_component_type: nil,
          node_scope: nil
        }

        {satisfied, details} = verdict(overlay, identity)
        row(identity, satisfied, details, checked_at)
      end

    story_ids = Enum.map(stories, & &1.id)

    records =
      from(n in GraphStore.project_rows(), where: n.story_id in ^story_ids and n.name in ^names)
      |> Repo.all()

    ctx = %{stories: stories, components: [], components_by_id: %{}}
    nodes = Projection.rehydrate_all(records ++ reported, ctx)
    {nodes, Projection.edges_for(project_id, nodes)}
  end

  # The copy's file verdicts by name, reported or computed from its files, or
  # one answer for every node when there is neither.
  defp overlay(scope) do
    case CopyOverlay.verdicts_at(scope) do
      {_source, verdicts, at} ->
        {Map.new(verdicts, &{&1["name"], wire_sweep(&1)}), at}

      :no_checkout ->
        {{:none, @no_checkout}, nil}
    end
  end

  defp verdict({:none, reason}, _identity), do: {false, %{"reason" => reason}}

  defp verdict(sweeps, identity) do
    case Map.get(sweeps, identity.name) do
      nil ->
        {false, %{"reason" => @awaiting}}

      {default, default_details, except} ->
        Map.get(except, identity.entity_id, {default, default_details})
    end
  end

  defp wire_sweep(sweep) do
    except =
      Map.new(sweep["except"], fn [id, satisfied, details] -> {id, {satisfied, details}} end)

    {sweep["default"], sweep["default_details"], except}
  end

  defp sweep(sweep) do
    except = Map.new(sweep.except, &{&1.entity_id, {&1.satisfied, &1.details}})
    {sweep.default, sweep.default_details, except}
  end

  defp row(identity, satisfied, details, checked_at) do
    owner =
      case identity.entity_type do
        "component" -> %{component_id: identity.entity_id}
        "story" -> %{story_id: identity.entity_id}
        "project" -> %{project_id: identity.entity_id}
      end

    struct(
      Node,
      Map.merge(owner, %{
        name: identity.name,
        satisfied: satisfied,
        details: details || %{},
        checked_at: checked_at,
        owner_component_type: identity.owner_component_type,
        node_scope: identity.node_scope && to_string(identity.node_scope)
      })
    )
  end

  # The project's record verdicts for the entities the reader sees.
  defp record_rows(project_id, ctx) do
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    issue_ids =
      for issue <- Map.get(ctx, :story_issues, []), issue.story_id in story_ids, do: issue.id

    from(n in GraphStore.project_rows(),
      where:
        n.component_id in ^component_ids or n.story_id in ^story_ids or
          n.issue_id in ^issue_ids or n.project_id == ^project_id
    )
    |> Repo.all()
  end
end
