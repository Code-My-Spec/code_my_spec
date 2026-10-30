defmodule CodeMySpec.Requirements.CopyGraph do
  @moduledoc """
  A checkout's graph, read from what is kept once per project and what its
  harness reported: nothing is stored per checkout.

  Nodes are the templates' for the entities the reader sees
  (`RequirementGraph.defined_nodes/3`). Each verdict comes from the project's
  record verdicts (`project_requirements`), the copy's overlay (its file
  verdicts, `CopyOverlay`), or its three placement gates, settled on read
  (`Handlers.gate_verdicts/1`). Edges are the project's among those nodes.

  Not yet served: it is built beside `Projection.load/2` and compared with it
  until the switch. See knowledge/requirements_graph/overlay.md.
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

  @doc "The graph at the scope's vantage, as `{nodes, edges}`, like `Projection.load/2`."
  @spec load(Scope.t(), map()) :: {[Requirement.t()], [map()]}
  def load(%Scope{active_project_id: project_id} = scope, ctx) do
    config = Configurations.get_or_create(scope)
    defined = RequirementGraph.defined_nodes(ctx, config, project_id)
    copy_names = Handlers.copy_names()
    gate_names = Handlers.gate_names()

    {overlay, checked_at} = overlay(project_id, Projection.vantage(scope))
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

  # The copy's file verdicts by name, or one answer for every node when there
  # is no report to read.
  defp overlay(project_id, vantage) do
    case CopyOverlay.at(project_id, vantage) do
      {:reported, verdicts, at} ->
        {Map.new(verdicts, &{&1["name"], wire_sweep(&1)}), DateTime.to_naive(at)}

      :awaiting ->
        {{:none, @awaiting}, nil}

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
