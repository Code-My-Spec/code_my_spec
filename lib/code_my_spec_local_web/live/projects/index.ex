defmodule CodeMySpecLocalWeb.ProjectsLive.Index do
  @moduledoc """
  Lists all local projects (those with a local_path set).
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, page_title: "Projects")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="prose prose-invert max-w-none">
      <h1>Projects</h1>

      <div :if={@projects == []} class="alert alert-info">
        <span>No local projects found. Use the MCP init_project tool to link a project.</span>
      </div>

      <div class="not-prose grid gap-4">
        <.project_card :for={project <- @projects} project={project} />
      </div>
    </div>
    """
  end

  defp project_card(assigns) do
    ~H"""
    <a
      href={"/projects/#{project_slug(@project)}"}
      class="card bg-base-200 shadow-md hover:shadow-lg transition-shadow"
    >
      <div class="card-body">
        <h2 class="card-title">{@project.name}</h2>
        <p :if={@project.local_path} class="text-sm opacity-70 font-mono truncate">
          {@project.local_path}
        </p>
      </div>
    </a>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
