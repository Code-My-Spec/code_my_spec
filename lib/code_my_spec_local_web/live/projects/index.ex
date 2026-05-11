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
    client_user_id = active_client_user_id()
    projects = Projects.list_local_projects(client_user_id)

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       page_title: "Projects",
       authed?: OAuthClient.authenticated?(),
       linked_project?: Projects.any_linked_project_for_client_user?(client_user_id)
     )}
  end

  defp active_client_user_id do
    case OAuthClient.get_active_client_user() do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  @impl true
  def handle_params(%{"project" => project_id}, _uri, socket) when is_binary(project_id) do
    case Projects.get_project_by_id(project_id) do
      %{local_path: lp} = project when is_binary(lp) ->
        slug = project_slug(project)
        {:noreply, push_navigate(socket, to: ~p"/projects/#{slug}")}

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

  defp auth_state(authed?) do
    if authed?, do: "done", else: "active"
  end

  defp linked_project_state(authed?, linked_project?) do
    cond do
      linked_project? -> "done"
      authed? -> "active"
      true -> "pending"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={nil} section={:projects} page_title="Projects">
      <.local_install_ladder
        :if={!local_install_done?(@authed?, @linked_project?)}
        authed?={@authed?}
        linked_project?={@linked_project?}
      />

      <div class="mb-6">
        <h1 class="text-3xl font-bold">Projects</h1>
        <p class="text-base-content/60 mt-1">Projects linked to a local working directory.</p>
      </div>

      <div :if={@projects == []} role="alert" class="alert flex flex-col items-start gap-2">
        <span class="font-semibold">No projects linked to this machine yet.</span>
        <span class="text-sm opacity-80">
          From Claude Code inside a Phoenix project's root directory, run
          <code class="kbd kbd-sm">/codemyspec:init</code>
          to link it. The plugin attaches to whichever directory Claude Code is
          running in — there's no project picker beyond <code class="kbd kbd-sm">cd</code>.
        </span>
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

  defp local_install_ladder(assigns) do
    ~H"""
    <div data-test="local-install-ladder" class="mx-auto max-w-2xl flex flex-col gap-4 mb-8">
      <div
        data-test="auth-rung"
        data-state={auth_state(@authed?)}
        class="cms-onboarding"
        style={if !@authed?, do: "", else: ""}
      >
        <div class="flex items-center gap-4 px-6 py-5">
          <span class="cms-onboarding-eyebrow">// step 01 · auth</span>
          <span class="flex-1"></span>
          <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">Sign in</span>
        </div>
      </div>

      <div
        data-test="linked-project-rung"
        data-state={linked_project_state(@authed?, @linked_project?)}
        class="cms-onboarding"
        style={if !@authed? and !@linked_project?, do: "opacity: 0.55;", else: ""}
      >
        <div class="flex items-center gap-4 px-6 py-5">
          <span class="cms-onboarding-eyebrow">// step 02 · linked project</span>
          <span class="flex-1"></span>
          <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">Link a project</span>
        </div>
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
