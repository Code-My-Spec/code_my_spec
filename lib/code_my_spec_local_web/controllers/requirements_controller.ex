defmodule CodeMySpecLocalWeb.RequirementsController do
  @moduledoc """
  LLM API for project requirements status.

  Returns markdown responses listing requirement satisfaction status.
  Replaces the static .code_my_spec/status/ markdown files.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Prompts
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  def index(conn, _params) do
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

  def prompt(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope
    project = Repo.preload(scope.active_project, :requirements)
    requirement = Enum.find(project.requirements, &(&1.name == name))

    cond do
      is_nil(requirement) ->
        conn |> put_status(404) |> text("Requirement not found: #{name}")

      is_nil(requirement.satisfied_by) ->
        conn |> put_status(400) |> text("No task module for requirement: #{name}")

      true ->
        task = %{project_id: project.id, component_id: requirement.component_id, story_id: requirement.story_id}
        {:ok, parent_text} = requirement.satisfied_by.command(scope, task)

        prompt_text =
          case requirement.scope do
            :children ->
              checklist = requirement.details["checklist"] || requirement.details[:checklist] || []
              project_slug = project_slug(project)
              base_url = "/api/projects/#{project_slug}/requirements/#{name}"
              Prompts.build_children_prompt(parent_text, checklist, base_url)

            _ ->
              parent_text
          end

        text(conn, prompt_text)
    end
  end

  def child(conn, %{"name" => _name, "child_id" => child_id}) do
    scope = conn.assigns.current_scope
    mod = CodeMySpec.AgentTasks.ProjectSetup.find_step(child_id)

    if mod do
      case mod.command(scope, %{}) do
        {:ok, prompt_text} -> text(conn, prompt_text)
        {:error, reason} -> conn |> put_status(500) |> text("Error: #{inspect(reason)}")
      end
    else
      conn |> put_status(404) |> text("Step not found: #{child_id}")
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def show(conn, %{"name" => name}) do
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
