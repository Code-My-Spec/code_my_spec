defmodule CodeMySpecLocalWeb.HomeLive do
  @moduledoc """
  Project overview / dashboard — landing page for a single project.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
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
         assign(socket,
           project: project,
           scope: scope,
           slug: project_slug(project),
           dir_param: URI.encode_www_form(scope.cwd),
           page_title: project.name,
           error: nil
         )}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
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

        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
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
      </div>
    </Layouts.app>
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
