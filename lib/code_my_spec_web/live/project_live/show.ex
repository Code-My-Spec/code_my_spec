defmodule CodeMySpecWeb.ProjectLive.Show do
  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.ProjectLive.Components.OauthCredentials

  alias CodeMySpec.Projects

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <.header>
        Project {@project.name}
        <:subtitle>This is a project record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/app/projects"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button navigate={~p"/app/projects/#{@project}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit project
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Name">{@project.name}</:item>
        <:item title="Code repo">{@project.code_repo}</:item>
        <:item title="Docs repo">{@project.docs_repo}</:item>
        <:item title="Status">{@project.status}</:item>
        <:item title="Setup error">{@project.setup_error}</:item>
      </.list>

      <.oauth_credentials
        project={@project}
        oauth_app={@oauth_app}
        plaintext_secret={@plaintext_secret}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Projects.subscribe_projects(socket.assigns.current_scope)
    end

    project =
      socket.assigns.current_scope
      |> Projects.get_project!(id)
      |> Projects.preload_oauth_application()

    {:ok,
     socket
     |> assign(:page_title, "Show Project")
     |> assign(:project, project)
     |> assign(:oauth_app, project.oauth_application)
     |> assign(:plaintext_secret, nil)}
  end

  @impl true
  def handle_event("generate_oauth_app", _params, socket) do
    case Projects.get_or_create_oauth_app(
           socket.assigns.current_scope,
           socket.assigns.project
         ) do
      {:ok, project, plaintext_secret} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:oauth_app, project.oauth_application)
         |> assign(:plaintext_secret, plaintext_secret)
         |> put_flash(:info, "OAuth credentials generated. Copy the secret now — it won't be shown again.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate OAuth credentials.")}
    end
  end

  def handle_event("regenerate_oauth_secret", _params, socket) do
    case Projects.regenerate_oauth_secret(
           socket.assigns.current_scope,
           socket.assigns.project
         ) do
      {:ok, project, plaintext_secret} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:oauth_app, project.oauth_application)
         |> assign(:plaintext_secret, plaintext_secret)
         |> put_flash(:info, "Secret regenerated. Copy the new secret now.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate secret.")}
    end
  end

  def handle_event("delete_oauth_app", _params, socket) do
    case Projects.delete_oauth_app(
           socket.assigns.current_scope,
           socket.assigns.project
         ) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:oauth_app, nil)
         |> assign(:plaintext_secret, nil)
         |> put_flash(:info, "OAuth credentials deleted.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete OAuth credentials.")}
    end
  end

  @impl true
  def handle_info(
        {:updated, %CodeMySpec.Projects.Project{id: id} = project},
        %{assigns: %{project: %{id: id}}} = socket
      ) do
    project = Projects.reload_oauth_application(project)

    {:noreply,
     assign(socket,
       project: project,
       oauth_app: project.oauth_application
     )}
  end

  def handle_info(
        {:deleted, %CodeMySpec.Projects.Project{id: id}},
        %{assigns: %{project: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current project was deleted.")
     |> push_navigate(to: ~p"/app/projects")}
  end

  def handle_info({type, %CodeMySpec.Projects.Project{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end
end
