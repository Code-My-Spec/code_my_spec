defmodule CodeMySpecLocalWeb.Tasks.NextTaskLive do
  @moduledoc """
  Preview of what the agent sees from `get_next_requirement`.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      markdown =
        case RequirementGraph.next_actionable(scope) do
          [] -> "# All requirements satisfied\n\nNo actionable tasks remain."
          nodes -> RequirementsMapper.format_next_requirements(nodes)
        end

      {:noreply,
       assign(socket,
         project: project,
         markdown: markdown,
         page_title: "#{project.name} — Next Task",
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:next_task}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">Next Task</h1>
          <p class="text-base-content/60 mt-1">Preview of what the agent sees from <code class="kbd kbd-sm">get_next_requirement</code>.</p>
        </div>

        <div :if={@markdown} class="prose max-w-none bg-base-200 border border-base-300 rounded-box p-6">
          {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
        </div>

        <div :if={!@markdown} class="text-base-content/50">Loading…</div>
      </div>
    </Layouts.app>
    """
  end
end
