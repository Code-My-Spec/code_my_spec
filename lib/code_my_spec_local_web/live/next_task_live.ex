defmodule CodeMySpecLocalWeb.NextTaskLive do
  @moduledoc """
  Human interface for the next actionable task.

  Preview only — shows what the next task would be without drafting
  it onto a session. The API endpoint handles task creation.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.NextTaskMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      result = ProjectCoordinator.get_next_actions(scope)
      markdown = NextTaskMarkdown.render(result, scope, project)

      {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="text-red-400">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end
end
