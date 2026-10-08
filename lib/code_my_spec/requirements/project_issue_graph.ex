defmodule CodeMySpec.Requirements.ProjectIssueGraph do
  @moduledoc """
  Project issue branches for the requirements graph view.

  Reads current issue records, independently of the cached story/component
  projection. This graph-first projection does not change agent dispatch.
  Only accepted project issues at the configured blocking severity enter it;
  story-linked issues remain owned by their story. Resolved/dismissed issues
  leave the open-work graph, satisfying the aggregate when none remain.
  """
  alias CodeMySpec.{Configurations, Issues}
  alias CodeMySpec.Requirements.{Requirement, Topology}

  def read(scope, graph) do
    threshold = Configurations.fix_issues_min_severity(scope)
    issues = Issues.list_by_status_and_min_severity(scope, :accepted, threshold)
    project(graph, scope.active_project_id, issues)
  end

  def project(graph, project_id, issues) do
    issues =
      issues
      |> Enum.filter(&(&1.status == :accepted and is_nil(&1.story_id)))
      |> Enum.sort_by(& &1.id)

    setup = {"project", project_id, "qa_setup"}
    aggregate = {"project", project_id, "issues_resolved"}
    present = MapSet.new(graph.nodes, &Topology.node_key/1)

    if MapSet.member?(present, setup) and MapSet.member?(present, aggregate) do
      issue_nodes = Enum.flat_map(issues, &nodes/1)
      branches = Enum.flat_map(issues, &edges(&1, setup, aggregate))
      # Replace the aggregate's old incoming gate; stories join independently
      # at the project's existing final QA gate, never before issue assignment.
      edges = Enum.reject(graph.edges, &(&1.to == aggregate))
      edges = edges ++ if(issues == [], do: [%{from: setup, to: aggregate}], else: branches)

      nodes =
        Enum.map(graph.nodes, fn node ->
          if Topology.node_key(node) == aggregate do
            %{
              node
              | satisfied: issues == [],
                satisfied_by: nil,
                role: nil,
                description: "All blocking project-scoped issues are completed",
                details: %{"open_project_issues" => length(issues)}
            }
          else
            node
          end
        end) ++ issue_nodes

      blocked = Topology.descendants_of(Enum.reject(nodes, & &1.satisfied), edges)
      by_key = Map.new(nodes, &{Topology.node_key(&1), &1})

      aggregate_node = Map.fetch!(by_key, aggregate)
      downstream = Topology.descendants_of([aggregate_node], edges)

      reopened =
        Enum.filter(
          nodes,
          &(MapSet.member?(downstream, Topology.node_key(&1)) and
              not is_nil(&1.satisfied_by) and not Requirement.waiting?(&1))
        )

      actionable =
        (graph.actionable ++ issue_nodes ++ reopened)
        |> Enum.map(&Map.fetch!(by_key, Topology.node_key(&1)))
        |> Enum.reject(
          &(&1.satisfied or Topology.node_key(&1) == aggregate or
              MapSet.member?(blocked, Topology.node_key(&1)))
        )
        |> Enum.uniq_by(&Topology.node_key/1)

      %{graph | nodes: nodes, edges: edges, actionable: actionable}
    else
      graph
    end
  end

  defp nodes(issue) do
    assigned = not is_nil(issue.assigned_working_copy_id)
    submitted = issue.awaiting_role in [:qa, :promote]

    for {name, satisfied, role} <- [
          {"assigned", assigned, :main},
          {"submitted", submitted, :coding},
          {"completed", issue.status == :resolved,
           if(issue.awaiting_role == :promote, do: :coding, else: :qa)}
        ] do
      %Requirement{
        entity_type: "issue",
        entity_id: issue.id,
        entity_name: issue.title,
        name: name,
        satisfied: satisfied,
        role: role,
        description: description(name),
        details: %{
          "assigned_working_copy_id" => issue.assigned_working_copy_id,
          "awaiting_role" => issue.awaiting_role,
          "status" => issue.status
        }
      }
    end
  end

  defp description("assigned"), do: "The issue is assigned to a working copy's team"
  defp description("submitted"), do: "Coding has submitted the fix for QA"
  defp description("completed"), do: "QA passed and the fix landed; the issue is resolved"

  defp edges(issue, setup, aggregate) do
    [
      setup,
      {"issue", issue.id, "assigned"},
      {"issue", issue.id, "submitted"},
      {"issue", issue.id, "completed"},
      aggregate
    ]
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> %{from: from, to: to} end)
  end
end
