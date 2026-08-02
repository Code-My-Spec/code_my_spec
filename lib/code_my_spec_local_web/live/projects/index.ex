defmodule CodeMySpecLocalWeb.ProjectsLive.Index do
  @moduledoc """
  Lists all local projects (those with a local_path set).

  Story 701 layer: when neither rung of the local-install ladder is
  done — i.e. the user isn't authed locally OR no project has a
  `local_path` — render the local-install ladder above the projects
  list. Once both rungs are done, the ladder is hidden and only the
  projects list shows.

  Also handles `?project=<id>` from the dashboard handoff link: if
  the local DB knows the project (it's been synced + linked), redirect
  the user straight into that project's onboarding ladder instead of
  dropping them on the picker.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Projects

  @impl true
  def mount(_params, _session, socket) do
    {client_user_id, client_user_email} = active_client_user()
    projects = Projects.list_local_projects(client_user_id)

    {:ok,
     assign(socket,
       projects: projects,
       client_user_id: client_user_id,
       project: nil,
       page_title: "Projects",
       muster_sync?: Application.get_env(:code_my_spec, :muster_sync_enabled, false),
       authed?: OAuthClient.authenticated?(),
       client_user_email: client_user_email,
       linked_project?: Projects.any_linked_project_for_client_user?(client_user_id)
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = %CodeMySpec.Users.Scope{
      user: %CodeMySpec.ClientUsers.ClientUser{id: socket.assigns.client_user_id || 0},
      user_id: socket.assigns.client_user_id || 0,
      active_account_id: nil
    }

    with %CodeMySpec.Projects.Project{} = project <- Projects.get_project_by_id(id),
         {:ok, _} <- Projects.delete_project(scope, project) do
      {:noreply,
       socket
       |> put_flash(:info, "Project deleted")
       |> assign(:projects, Projects.list_local_projects(socket.assigns.client_user_id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete project")}
    end
  end

  defp active_client_user do
    case OAuthClient.get_active_client_user() do
      {:ok, %{id: id, email: email}} -> {id, email}
      _ -> {nil, nil}
    end
  end

  @impl true
  def handle_params(%{"project" => project_id}, _uri, socket) when is_binary(project_id) do
    case Projects.get_project_by_id(project_id) do
      %{local_path: lp} = project when is_binary(lp) ->
        slug = project_slug(project)
        {:noreply, push_navigate(socket, to: ~p"/app/projects/#{slug}")}

      _ ->
        # Unknown id (or known but not linked locally) — fall back to
        # the projects list silently. No flash; the user can pick from
        # the list or run the MCP init flow.
        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp local_install_done?(authed?, linked_project?) do
    authed? and linked_project?
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={nil} section={:projects} page_title="Projects">
      <%!-- The Muster install/link ladder only shows when Muster sync is opted
            in; standalone CodeMySpec is just a local project manager. --%>
      <.local_install_ladder
        :if={@muster_sync? && !local_install_done?(@authed?, @linked_project?)}
        authed?={@authed?}
        client_user_email={@client_user_email}
        linked_project?={@linked_project?}
      />

      <div class="mb-6 flex items-start justify-between gap-4">
        <div>
          <h1>Projects</h1>
          <p class="text-base-content/60 mt-1 font-mono text-sm">
            Local codebases CodeMySpec is pointed at.
          </p>
        </div>
        <.link navigate={~p"/app/projects/new"} class="btn btn-primary" data-test="new-project">
          New project
        </.link>
      </div>

      <div :if={@projects == []} class="text-base-content/60">
        No projects yet. <.link navigate={~p"/app/projects/new"} class="link">Create one</.link>.
      </div>

      <div :if={@projects != []} class="grid gap-4 sm:grid-cols-2">
        <div
          :for={project <- @projects}
          class="card bg-base-200 border border-base-300 hover:border-primary transition"
        >
          <div class="card-body">
            <.link navigate={~p"/app/projects/#{project_slug(project)}"} class="hover:underline">
              <h2 class="card-title">{project.name}</h2>
              <p :if={project.local_path} class="text-sm opacity-60 font-mono truncate">
                {project.local_path}
              </p>
            </.link>
            <div class="card-actions justify-end mt-2">
              <.link navigate={~p"/app/projects/#{project_slug(project)}/edit"} class="btn btn-xs btn-ghost">
                Edit
              </.link>
              <button
                type="button"
                phx-click="delete"
                phx-value-id={project.id}
                data-confirm={"Delete project #{project.name}? This only removes the local record."}
                class="btn btn-xs btn-ghost text-error"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp local_install_ladder(assigns) do
    ~H"""
    <div data-test="local-install-ladder" class="mx-auto max-w-2xl flex flex-col gap-4 mb-8">
      <.auth_rung authed?={@authed?} client_user_email={@client_user_email} />
      <.linked_project_rung authed?={@authed?} linked_project?={@linked_project?} />
    </div>
    """
  end

  defp auth_rung(%{authed?: true} = assigns) do
    ~H"""
    <div data-test="auth-rung" data-state="done" class="cms-onboarding">
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">// step 01 · auth</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">
          ✓ Signed in<span :if={@client_user_email}> as {@client_user_email}</span>
        </span>
      </div>
    </div>
    """
  end

  defp auth_rung(assigns) do
    ~H"""
    <.link
      navigate={~p"/app/auth"}
      data-test="auth-rung"
      data-state="active"
      class="cms-onboarding cms-onboarding-link block"
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">// step 01 · auth</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-cta">
          <span>▸</span> Sign in
        </span>
      </div>
    </.link>
    """
  end

  # Project linking happens via `/codemyspec:init` in Claude Code, so the
  # rung's "done"/"active" CTA is a copy-able command, not a navigation.
  # When not yet authed, the rung is dim and inert — the auth rung above
  # has to land first.
  defp linked_project_rung(%{authed?: true, linked_project?: false} = assigns) do
    ~H"""
    <div data-test="linked-project-rung" data-state="active" class="cms-onboarding">
      <div class="flex items-center gap-4 px-6 py-5 flex-wrap">
        <span class="cms-onboarding-eyebrow">// step 02 · linked project</span>
        <span class="flex-1"></span>
        <code class="kbd kbd-sm" data-test="linked-project-rung-cmd">/codemyspec:init</code>
        <button
          type="button"
          class="copy-btn btn btn-xs btn-primary"
          data-copy="/codemyspec:init"
          data-test="linked-project-rung-copy"
          aria-label="Copy /codemyspec:init to clipboard"
        >
          Copy
        </button>
      </div>
      <div class="px-6 pb-4 -mt-1 text-xs opacity-60 font-mono">
        Run inside Claude Code from your Phoenix project's root directory.
      </div>
    </div>
    """
  end

  defp linked_project_rung(%{authed?: true, linked_project?: true} = assigns) do
    ~H"""
    <div data-test="linked-project-rung" data-state="done" class="cms-onboarding">
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">// step 02 · linked project</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">✓ Linked</span>
      </div>
    </div>
    """
  end

  defp linked_project_rung(assigns) do
    ~H"""
    <div
      data-test="linked-project-rung"
      data-state="pending"
      class="cms-onboarding"
      style="opacity: 0.55;"
      aria-disabled="true"
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">// step 02 · linked project</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">Link a project</span>
      </div>
    </div>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
