defmodule CodeMySpecLocalWeb.RequirementsController do
  @moduledoc """
  LLM API for project requirements status.

  Returns markdown responses listing requirement satisfaction status.
  Replaces the static .code_my_spec/status/ markdown files.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  def index(conn, %{"project_id" => _project_id}) do
    scope = conn.assigns.current_scope
    project = Repo.preload(scope.active_project, :requirements)
    actionable = Requirements.next_actionable(scope, project)

    markdown =
      RequirementsMarkdown.index(%{
        project: project,
        requirements: project.requirements || [],
        actionable: actionable
      })

    text(conn, markdown)
  end

  def show(conn, %{"project_id" => _project_id, "name" => name}) do
    scope = conn.assigns.current_scope
    project = Repo.preload(scope.active_project, :requirements)
    requirement = Enum.find(project.requirements, &(&1.name == name))

    if requirement do
      markdown = RequirementsMarkdown.show(%{project: project, requirement: requirement})
      text(conn, markdown)
    else
      conn |> put_status(404) |> text("Requirement not found: #{name}")
    end
  end
end
