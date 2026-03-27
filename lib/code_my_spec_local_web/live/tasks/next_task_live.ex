defmodule CodeMySpecLocalWeb.Tasks.NextTaskLive do
  @moduledoc """
  Human interface for the next actionable task.

  Preview only — shows what the next task would be without drafting
  it onto a session. Agents use the DraftTask MCP tool instead.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, result: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      result = Requirements.next_actionable_project(scope)
      {:noreply, assign(socket, project: project, result: result, error: nil)}
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

    <div :if={@result}>
      {render_result(assigns)}
    </div>

    <div :if={!@result && !@error} class="text-base-content/50">
      Loading...
    </div>
    """
  end

  defp render_result(%{result: [requirement | _]} = assigns) do
    assigns = assign(assigns, :requirement, requirement)

    ~H"""
    <div class="prose prose-invert max-w-none">
      <h1>Next Task: {@requirement.name}</h1>
      <p>{@requirement.description}</p>
      <p :if={@requirement.satisfied_by}>
        <strong>Task:</strong> {inspect(@requirement.satisfied_by) |> String.split(".") |> List.last()}
      </p>
      <p>
        <strong>Execution:</strong> {to_string(@requirement.execution_type)}
        | <strong>Validation:</strong> {to_string(@requirement.validation_type)}
      </p>
    </div>
    """
  end

  defp render_result(%{result: []} = assigns) do
    ~H"""
    <div class="prose prose-invert max-w-none">
      <h1>All requirements satisfied</h1>
      <p>No actionable tasks remain.</p>
    </div>
    """
  end

  defp render_result(assigns) do
    ~H""
  end
end
