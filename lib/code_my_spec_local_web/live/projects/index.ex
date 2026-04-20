defmodule CodeMySpecLocalWeb.ProjectsLive.Index do
  @moduledoc """
  Lists all local projects (those with a local_path set).
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, page_title: "Projects")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={nil} section={:projects} page_title="Projects">
      <div class="mb-6">
        <h1 class="text-3xl font-bold">Projects</h1>
        <p class="text-base-content/60 mt-1">Projects linked to a local working directory.</p>
      </div>

      <div :if={@projects == []} role="alert" class="alert">
        <span>No local projects found. Use the MCP <code class="kbd kbd-sm">init_project</code> tool to link a project.</span>
      </div>

      <div :if={@projects != []} class="grid gap-4 sm:grid-cols-2">
        <.link
          :for={project <- @projects}
          navigate={~p"/projects/#{project_slug(project)}"}
          class="card bg-base-200 border border-base-300 hover:border-primary hover:shadow-lg transition"
        >
          <div class="card-body">
            <h2 class="card-title">{project.name}</h2>
            <p :if={project.local_path} class="text-sm opacity-60 font-mono truncate">
              {project.local_path}
            </p>
          </div>
        </.link>
      </div>
    </Layouts.app>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
