defmodule CodeMySpecWeb.ProjectLive.Form do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage project records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="project-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:module_name]} type="text" label="Module Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Code repo</span>
          </label>
          <div class="join w-full">
            <input
              type="text"
              id={@form[:code_repo].id}
              name={@form[:code_repo].name}
              value={@form[:code_repo].value}
              class="input input-bordered join-item flex-1"
              placeholder="https://github.com/username/repo-code"
            />
            <button
              type="button"
              phx-click="create_code_repo"
              disabled={is_nil(@project.name) || @project.name == ""}
              class="btn join-item"
            >
              Create
            </button>
          </div>
        </div>
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Docs repo</span>
          </label>
          <div class="join w-full">
            <input
              type="text"
              id={@form[:docs_repo].id}
              name={@form[:docs_repo].name}
              value={@form[:docs_repo].value}
              class="input input-bordered join-item flex-1"
              placeholder="https://github.com/username/repo-docs"
            />
            <button
              type="button"
              phx-click="create_docs_repo"
              disabled={is_nil(@project.name) || @project.name == ""}
              class="btn join-item"
            >
              Create
            </button>
          </div>
        </div>
        <.input field={@form[:client_api_url]} type="text" label="Client API URL" />
        <.input
          field={@form[:google_analytics_property_id]}
          type="text"
          label="Google Analytics Property ID"
        />
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Deploy Key</span>
          </label>
          <input type="hidden" name={@form[:deploy_key].name} value={@deploy_key_value} />
          <div class="join w-full">
            <input
              type="text"
              id={@form[:deploy_key].id}
              value={@deploy_key_value}
              readonly
              class="input input-bordered join-item flex-1"
              placeholder="Click Generate to create a deploy key"
            />
            <button type="button" phx-click="generate_deploy_key" class="btn join-item">
              Generate
            </button>
          </div>
        </div>
        <footer>
          <.button phx-disable-with="Saving...">Save Project</.button>
          <.button navigate={return_path(@current_scope, @return_to, @project)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Projects.get_project!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit Project")
    |> assign(:project, project)
    |> assign(:deploy_key_value, project.deploy_key)
    |> assign(:form, to_form(Projects.change_project(socket.assigns.current_scope, project)))
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{account_id: socket.assigns.current_scope.active_account_id}

    socket
    |> assign(:page_title, "New Project")
    |> assign(:project, project)
    |> assign(:deploy_key_value, nil)
    |> assign(:form, to_form(Projects.change_project(socket.assigns.current_scope, project)))
  end

  @impl true
  def handle_event("validate", %{"project" => project_params}, socket) do
    changeset =
      Projects.change_project(
        socket.assigns.current_scope,
        socket.assigns.project,
        project_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("generate_deploy_key", _params, socket) do
    # Generate a secure random deploy key (64 bytes = 128 hex characters)
    deploy_key = :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

    {:noreply, assign(socket, deploy_key_value: deploy_key)}
  end

  def handle_event("create_code_repo", params, socket) do
    create_github_repo(socket, :code_repo, params, "")
  end

  def handle_event("create_docs_repo", params, socket) do
    create_github_repo(socket, :docs_repo, params, "-docs")
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    save_project(socket, socket.assigns.live_action, project_params)
  end

  defp save_project(socket, :edit, project_params) do
    case Projects.update_project(
           socket.assigns.current_scope,
           socket.assigns.project,
           project_params
         ) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, project)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_project(socket, :new, project_params) do
    case Projects.create_project(socket.assigns.current_scope, project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, project)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(_scope, "index", _project), do: ~p"/app/projects"
  defp return_path(_scope, "show", project), do: ~p"/app/projects/#{project}"

  defp create_github_repo(socket, repo_type, params, suffix) do
    project = socket.assigns.project

    case Projects.create_github_repo(
           socket.assigns.current_scope,
           project,
           repo_type,
           params,
           suffix
         ) do
      {:ok, repo_url} ->
        # Update the form with the new repo URL
        attrs = Map.put(%{}, repo_type, repo_url)

        changeset =
          Projects.change_project(
            socket.assigns.current_scope,
            project,
            attrs
          )

        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:info, "Repository created successfully: #{repo_url}")}

      {:error, :github_not_connected} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please connect your GitHub account first")}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to create GitHub repo: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to create repository. Please try again.")}
    end
  end
end
