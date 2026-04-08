defmodule CodeMySpecWeb.ProjectsChannel do
  @moduledoc """
  Channel for clients to receive real-time project change notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for projects in that account, relayed from the Projects PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.Projects.Project

  @impl true
  def join("projects:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{scope.user.id}:projects")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:created, %Project{} = project}, socket) do
    push(socket, "project_created", serialize_project(project))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:updated, %Project{} = project}, socket) do
    push(socket, "project_updated", serialize_project(project))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:deleted, %Project{} = project}, socket) do
    push(socket, "project_deleted", %{id: project.id})
    {:noreply, socket}
  end

  defp serialize_project(%Project{} = project) do
    %{
      id: project.id,
      name: project.name,
      description: project.description,
      module_name: project.module_name,
      status: project.status,
      require_specs: project.require_specs,
      require_unit_tests: project.require_unit_tests,
      local_path: project.local_path,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end
end
