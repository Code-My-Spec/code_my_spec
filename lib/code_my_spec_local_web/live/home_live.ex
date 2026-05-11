defmodule CodeMySpecLocalWeb.HomeLive do
  @moduledoc """
  Project overview / dashboard — landing page for a single project.

  When the project has zero stories the page renders the per-project
  onboarding ladder (story 701) — three rungs (init, project setup,
  first story) using the same chamfered shell + "// step 0N · <name>"
  eyebrow as the dashboard's ladder. Once the project has at least
  one story the page falls back to the standard dash-card grid.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Events
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, scope: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        {:noreply,
         socket
         |> assign(
           project: project,
           scope: scope,
           slug: project_slug(project),
           dir_param: URI.encode_www_form(scope.cwd),
           page_title: project.name,
           error: nil
         )
         |> assign_ladder_state(project, scope)}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  defp assign_ladder_state(socket, project, scope) do
    init_done? = Events.exists?("local_init_complete", project_id: project.id)
    setup_done? = Events.exists?("local_project_setup_complete", project_id: project.id)
    stories_count = safe_count_stories(scope)
    has_stories? = stories_count > 0

    socket
    |> assign(:init_done?, init_done?)
    |> assign(:setup_done?, setup_done?)
    |> assign(:stories_count, stories_count)
    |> assign(:has_stories?, has_stories?)
    |> assign(:active_rung, active_rung(init_done?, setup_done?, has_stories?))
  end

  # Stories are moving from the dashboard server to the local CLI DB.
  # During the migration window the server-side stories table may be
  # absent (drop_stories_and_attached). Treat any DB-side absence as
  # "no stories" so the per-project ladder still renders correctly.
  defp safe_count_stories(scope) do
    length(Stories.list_stories(scope))
  rescue
    Postgrex.Error -> 0
    DBConnection.ConnectionError -> 0
  end

  defp active_rung(false, _, _), do: :init
  defp active_rung(true, false, _), do: :project_setup
  defp active_rung(true, true, false), do: :first_story
  defp active_rung(true, true, true), do: nil

  defp rung_state(rung, active, init_done?, setup_done?, has_stories?) do
    cond do
      rung == active -> "active"
      rung == :init and init_done? -> "done"
      rung == :project_setup and setup_done? -> "done"
      rung == :first_story and has_stories? -> "done"
      true -> "pending"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} section={:overview} page_title={assigns[:page_title]}>
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@project && !@error}>
        <div class="mb-8">
          <h1 class="text-3xl font-bold">{@project.name}</h1>
          <p :if={@project.local_path} class="text-sm opacity-60 font-mono mt-1">{@project.local_path}</p>
        </div>

        <.per_project_ladder :if={!@has_stories?} {assigns} />

        <.dash_cards :if={@has_stories?} slug={@slug} />
      </div>
    </Layouts.app>
    """
  end

  defp per_project_ladder(assigns) do
    assigns =
      assign(assigns, :active, assigns.active_rung)

    ~H"""
    <div data-test="per-project-ladder" class="mx-auto max-w-2xl flex flex-col gap-4">
      <.rung
        rung={:init}
        eyebrow="// step 01 · init"
        label="Init"
        slug={@slug}
        state={rung_state(:init, @active, @init_done?, @setup_done?, @has_stories?)}
      />

      <.rung
        rung={:project_setup}
        eyebrow="// step 02 · project setup"
        label="Project setup"
        slug={@slug}
        state={rung_state(:project_setup, @active, @init_done?, @setup_done?, @has_stories?)}
      />

      <.rung
        rung={:first_story}
        eyebrow="// step 03 · first story"
        label="First story"
        slug={@slug}
        state={rung_state(:first_story, @active, @init_done?, @setup_done?, @has_stories?)}
      />
    </div>
    """
  end

  defp rung(%{rung: rung} = assigns) do
    test_id = rung_test_id(rung)
    assigns = assign(assigns, :test_id, test_id)

    ~H"""
    <div
      data-test={@test_id}
      data-state={@state}
      class="cms-onboarding"
      style={if @state == "pending", do: "opacity: 0.55;", else: ""}
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">{@eyebrow}</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">{@label}</span>
      </div>

      <.rung_cta :if={@state == "active"} rung={@rung} slug={@slug} />
    </div>
    """
  end

  defp rung_cta(%{rung: :init} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex items-center gap-3 flex-wrap">
      <.link
        navigate={~p"/projects/#{@slug}/init"}
        class="cms-onboarding-cta"
        data-test="init-rung-cta"
      >
        <span>▸</span> Open init checklist
      </.link>
      <span class="text-xs opacity-60">
        Step prompts ready to paste into Claude Code.
      </span>
    </div>
    """
  end

  defp rung_cta(%{rung: :project_setup} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex items-center gap-3 flex-wrap">
      <div class="flex items-center gap-2">
        <code class="kbd kbd-sm" data-test="project-setup-rung-cmd">/codemyspec:next</code>
        <button
          type="button"
          class="copy-btn btn btn-xs btn-primary"
          data-copy="/codemyspec:next"
          data-test="project-setup-rung-copy"
          aria-label="Copy /codemyspec:next to clipboard"
        >
          Copy
        </button>
      </div>
      <span class="text-xs opacity-60">
        Paste in Claude Code — the agent runs project setup automatically.
      </span>
    </div>
    """
  end

  defp rung_cta(%{rung: :first_story} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex flex-col gap-2">
      <div class="flex items-center gap-3 flex-wrap">
        <.link
          navigate={~p"/projects/#{@slug}/stories/new"}
          class="cms-onboarding-cta"
          data-test="first-story-rung-cta"
        >
          <span>▸</span> Write your first story
        </.link>
        <span class="text-xs opacity-60">— or let the agent guide you:</span>
      </div>
      <div class="flex items-center gap-2">
        <code class="kbd kbd-sm">/codemyspec:product interview</code>
        <button
          type="button"
          class="copy-btn btn btn-xs btn-ghost"
          data-copy="/codemyspec:product interview"
          aria-label="Copy /codemyspec:product interview to clipboard"
        >
          Copy
        </button>
      </div>
    </div>
    """
  end

  defp rung_test_id(:init), do: "init-rung"
  defp rung_test_id(:project_setup), do: "project-setup-rung"
  defp rung_test_id(:first_story), do: "first-story-rung"

  defp dash_cards(assigns) do
    ~H"""
    <div data-test="project-home-dashcards" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.dash_card title="Next Task" href={~p"/projects/#{@slug}/next-task"} desc="Pick up the next actionable requirement." />
      <.dash_card title="Files & Sync" href={~p"/projects/#{@slug}/files"} desc="Inspect tracked files and re-sync the projection." />
      <.dash_card title="Configuration" href={~p"/projects/#{@slug}/configuration"} desc="Quality gate and analyzer settings." />

      <.dash_card title="Requirements" href={~p"/projects/#{@slug}/requirements"} desc="Project-level requirement graph." />
      <.dash_card title="Stories" href={~p"/projects/#{@slug}/stories"} desc="User stories and acceptance criteria." />

      <.dash_card title="Issues" href={~p"/projects/#{@slug}/issues"} desc="Open problems and incoming triage." />
      <.dash_card title="Sessions" href={~p"/projects/#{@slug}/sessions"} desc="Agent session history." />
      <.dash_card title="Project Init" href={~p"/projects/#{@slug}/init"} desc="Bootstrap checklist for this directory." />

      <.dash_card title="Knowledge Base" href={~p"/projects/#{@slug}/knowledge"} desc="Shared methodology and rules." />
      <.dash_card title="Project Knowledge" href={~p"/projects/#{@slug}/project-knowledge"} desc="Project-specific docs and specs." />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :href, :string, required: true
  attr :desc, :string, required: true

  defp dash_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="card bg-base-200 border border-base-300 hover:border-primary hover:shadow-lg transition"
    >
      <div class="card-body p-5">
        <h2 class="card-title text-base">{@title}</h2>
        <p class="text-sm opacity-70">{@desc}</p>
      </div>
    </.link>
    """
  end

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
