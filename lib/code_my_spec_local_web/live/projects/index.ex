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
       project: nil,
       page_title: "Projects",
       authed?: OAuthClient.authenticated?(),
       client_user_email: client_user_email,
       linked_project?: Projects.any_linked_project_for_client_user?(client_user_id)
     )}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={nil} section={:projects} page_title="Projects">
      <.local_install_ladder
        :if={!local_install_done?(@authed?, @linked_project?)}
        authed?={@authed?}
        client_user_email={@client_user_email}
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
      navigate={~p"/auth"}
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
