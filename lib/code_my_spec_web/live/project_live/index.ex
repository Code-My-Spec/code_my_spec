defmodule CodeMySpecWeb.ProjectLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Projects

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Projects
        <:actions>
          <.button navigate={~p"/app/projects/new"}>
            <.icon name="hero-plus" /> New Project
          </.button>
        </:actions>
      </.header>

      <.table
        id="projects"
        rows={@streams.projects}
        row_click={fn {_id, project} -> JS.navigate(~p"/app/projects/#{project}") end}
      >
        <:col :let={{_id, project}} label="Name">{project.name}</:col>
        <:col :let={{_id, project}} label="Code repo">{project.code_repo}</:col>
        <:col :let={{_id, project}} label="Docs repo">{project.docs_repo}</:col>
        <:col :let={{_id, project}} label="Status">{project.status}</:col>
        <:col :let={{_id, project}} label="Setup error">{project.setup_error}</:col>
        <:action :let={{_id, project}}>
          <div class="sr-only">
            <.link navigate={~p"/app/projects/#{project}"}>Show</.link>
          </div>
          <.link navigate={~p"/app/projects/#{project}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, project}}>
          <.link
            phx-click={JS.push("delete", value: %{id: project.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Projects.subscribe_projects(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Projects")
     |> stream(:projects, Projects.list_projects(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(socket.assigns.current_scope, id)
    {:ok, _} = Projects.delete_project(socket.assigns.current_scope, project)

    {:noreply, stream_delete(socket, :projects, project)}
  end

  @impl true
  def handle_info({type, %CodeMySpec.Projects.Project{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(socket, :projects, Projects.list_projects(socket.assigns.current_scope), reset: true)}
  end
end
