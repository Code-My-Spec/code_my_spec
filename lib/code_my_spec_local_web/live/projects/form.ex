defmodule CodeMySpecLocalWeb.ProjectsLive.Form do
  @moduledoc """
  Create / edit a local project.

  Standalone project management: no account, no Muster. A project is a named
  local codebase (its `local_path`). Scope carries only the local user; the
  changeset leaves `account_id` nil.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.LocalScope

  @impl true
  def mount(params, _session, socket) do
    scope = local_scope()
    client_user_id = scope.user_id
    projects = Projects.list_local_projects(client_user_id)

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:scope, scope)
     |> assign(:client_user_id, client_user_id)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{}

    socket
    |> assign(:page_title, "New project")
    |> assign(:project, project)
    |> assign(:form, to_form(change_project(socket, project)))
  end

  defp apply_action(socket, :edit, %{"id" => name}) do
    case Projects.get_project_by_id(name) do
      {:ok, %Project{} = project} ->
        socket
        |> assign(:page_title, "Edit #{project.name}")
        |> assign(:project, project)
        |> assign(:form, to_form(change_project(socket, project)))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> push_navigate(to: ~p"/app/projects")
    end
  end

  @impl true
  def handle_event("validate", %{"project" => attrs}, socket) do
    changeset = change_project(socket, socket.assigns.project, attrs)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"project" => attrs}, socket) do
    save_project(socket, socket.assigns.live_action, attrs)
  end

  defp save_project(socket, :new, attrs) do
    attrs = Map.put(attrs, "client_user_id", socket.assigns.client_user_id)

    case Projects.create_project(scope(socket), attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> push_navigate(to: ~p"/app/projects/#{project.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_project(socket, :edit, attrs) do
    case Projects.update_project(scope(socket), socket.assigns.project, attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated")
         |> push_navigate(to: ~p"/app/projects/#{project.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Local scope: the single local user, no account. account_id stays nil.
  defp scope(socket), do: socket.assigns.scope

  defp change_project(socket, project, attrs \\ %{}) do
    Project.changeset(project, attrs, scope(socket))
  end

  # A scope carrying the local user (for broadcasts) but no account/project.
  defp local_scope do
    case LocalScope.for_local_cwd(File.cwd!()) do
      {:ok, %Scope{} = scope} -> %{scope | active_account_id: nil, active_project: nil}
      _ -> %Scope{user: default_local_user(), user_id: 0, active_account_id: nil}
    end
  end

  defp default_local_user do
    %CodeMySpec.ClientUsers.ClientUser{id: 0, email: "cli@localhost"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={assigns[:project]}
      section={:projects}
      page_title={@page_title}
    >
      <div class="mb-6">
        <h1 class="text-3xl font-bold">{@page_title}</h1>
        <p class="text-base-content/60 mt-1">
          A local project points CodeMySpec at a codebase on your machine.
        </p>
      </div>

      <.form
        for={@form}
        id="project-form"
        data-test="project-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4 max-w-xl"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input
          field={@form[:module_name]}
          type="text"
          label="Module name"
          placeholder="MyApp"
        />
        <.input
          field={@form[:local_path]}
          type="text"
          label="Local path"
          placeholder={File.cwd!()}
        />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <.input field={@form[:code_repo]} type="text" label="Code repo (optional)" />

        <div class="flex gap-2">
          <.button type="submit" phx-disable-with="Saving..." class="btn btn-primary">
            Save project
          </.button>
          <.link navigate={~p"/app/projects"} class="btn btn-ghost">Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
