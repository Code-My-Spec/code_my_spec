defmodule CodeMySpecLocalWeb.RequirementsController do
  @moduledoc """
  LLM API for project requirements status.

  Returns markdown responses from the computed requirement graph.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @doc """
  The **cached** graph, with what is needed to tell whether it moved.

  `index/2` answers from `compute_all/1` — it recomputes on every request and
  so can never show cache behaviour. That is right for an agent asking what to
  work on and useless for anyone asking whether the cache is being served, which
  is a question the system otherwise answers nowhere: `RequirementsLive`
  discards `computed_at`, and the only surface carrying watcher state is
  `/dev/state`, which exists solely under `dev_routes` and therefore not in
  test.

  So this returns JSON rather than markdown, and carries the diagnostics rather
  than only the answer:

    * `computed_at` — when the served graph was computed. Unchanged across two
      requests means the cache was served; advancing means it was recomputed.
    * `watcher` — whether a watcher is running, whether a pass is pending, when
      it last recomputed, and what its last recompute failed with. The last of
      those is the only way to tell a graph that has not changed from one that
      has stopped being able to.
    * `nodes` — name, entity, and satisfaction, which is what a caller
      comparing two answers actually diffs.

  Deliberately does not settle first. A caller wanting the post-settle answer
  can ask for one; a caller checking whether a write moved the graph must be
  able to see the state as it stands, and settling would erase the distinction
  being observed.
  """
  def graph(conn, params) do
    scope = scope_for(conn.assigns.current_scope, params)
    {nodes, computed_at, served_from} = cached_with_provenance(scope)

    json(conn, %{
      computed_at: computed_at,
      served_from: served_from,
      watcher: watcher_report(GraphWatcher.status(scope.active_project_id)),
      nodes: Enum.map(nodes, &node_report/1)
    })
  end

  # `cached_all/1` answers `computed_at: nil` on a miss — it computes, stores,
  # and reports nil for the answer it has just produced. That is ambiguous in
  # the worst way for a diagnostic surface: nil reads as "no answer" while
  # meaning "this read *is* the answer", so two reads around a write compare a
  # timestamp against nil and look like two computations when there was one.
  #
  # So a miss reads again. The second read hits the store the first one filled,
  # and `computed_at` then always means "when the computation serving this
  # answer was made". `served_from` keeps the distinction that was being carried
  # by nil, without overloading a timestamp to carry it.
  defp cached_with_provenance(scope) do
    case Requirements.cached_all(scope) do
      {_nodes, nil} ->
        {nodes, computed_at} = Requirements.cached_all(scope)
        {nodes, computed_at, "computed"}

      {nodes, computed_at} ->
        {nodes, computed_at, "cache"}
    end
  end

  # A requirement graph is a statement about a checkout. Without one the
  # preloader reads every checkout's files together, so a file present in one
  # and absent in another reads as present — which it warns about in as many
  # words, calling an agent path here a bug. Fine for a project-wide view and
  # wrong for any question about a particular copy, so `?working_copy=<id>`
  # asks the question that copy's agents would ask.
  defp scope_for(scope, %{"working_copy" => id}) when is_binary(id) and id != "",
    do: %{scope | active_working_copy_id: id}

  defp scope_for(scope, _params), do: scope

  defp watcher_report(nil), do: %{watching: false}

  defp watcher_report(status) do
    %{
      watching: true,
      pending: Map.get(status, :pending),
      last_recompute: Map.get(status, :last_recompute),
      last_error: error_report(Map.get(status, :last_error))
    }
  end

  # A failed recompute leaves every reader served the last good answer, which
  # looks correct and is frozen. Without this, the only way to notice is to
  # compare `last_recompute` against a change you already knew about.
  defp error_report(nil), do: nil
  defp error_report(%{at: at, message: message}), do: %{at: at, message: message}

  # `checked_at` per node, not only `computed_at` for the graph.
  #
  # "An observation recomputes what it touched and leaves the rest" is a
  # question about individual requirements, and one timestamp for the whole
  # graph cannot answer it — every node moves together whether or not the work
  # was necessary. A reader comparing these across two reads can see which
  # requirements actually cost something.
  #
  # `nil` means the node was computed on this request rather than read back.
  defp node_report(node) do
    %{
      name: node.name,
      entity_type: node.entity_type,
      entity_id: node.entity_id,
      satisfied: node.satisfied,
      checked_at: Map.get(node, :checked_at)
    }
  end

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)
    actionable = RequirementGraph.next_actionable(scope)

    markdown =
      RequirementsMarkdown.index(%{
        project: scope.active_project,
        nodes: nodes,
        actionable: actionable
      })

    text(conn, markdown)
  end

  def show(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    node =
      Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == name
      end)

    if node do
      markdown = RequirementsMarkdown.show(%{node: node})
      text(conn, markdown)
    else
      conn |> put_status(404) |> text("Requirement not found: #{name}")
    end
  end

  def prompt(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    node =
      Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == name
      end)

    cond do
      is_nil(node) ->
        conn |> put_status(404) |> text("Requirement not found: #{name}")

      is_nil(node.satisfied_by) ->
        conn |> put_status(400) |> text("No task module for requirement: #{name}")

      true ->
        task = %{project_id: scope.active_project_id}
        {:ok, prompt_text} = node.satisfied_by.command(scope, task)
        text(conn, prompt_text)
    end
  end

  def child(conn, %{"name" => _name, "child_id" => child_id}) do
    scope = conn.assigns.current_scope
    mod = ProjectSetup.find_step(child_id)

    if mod do
      case mod.command(scope, %{}) do
        {:ok, prompt_text} -> text(conn, prompt_text)
        {:error, reason} -> conn |> put_status(500) |> text("Error: #{inspect(reason)}")
      end
    else
      conn |> put_status(404) |> text("Step not found: #{child_id}")
    end
  end
end
