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
    {:ok, assign(socket, project: nil, markdown: nil, error: nil)}
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

      {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="alert alert-error">
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>

    <div :if={!@markdown && !@error} class="text-base-content/50">
      Loading...
    </div>
    """
  end
end
