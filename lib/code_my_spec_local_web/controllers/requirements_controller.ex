defmodule CodeMySpecLocalWeb.RequirementsController do
  @moduledoc """
  LLM API for project requirements status.

  Returns markdown responses from the computed requirement graph.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    nodes = RequirementGraph.compute_all(scope)
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
    nodes = RequirementGraph.compute_all(scope)

    node = Enum.find(nodes, fn n ->
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
    nodes = RequirementGraph.compute_all(scope)

    node = Enum.find(nodes, fn n ->
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
