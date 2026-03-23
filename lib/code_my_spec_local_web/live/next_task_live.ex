defmodule CodeMySpecLocalWeb.NextTaskLive do
  @moduledoc """
  Human interface for the next actionable task.

  Renders the same markdown as the LLM API via NextTaskMarkdown.
  """
  use CodeMySpecLocalWeb, :live_view

  require Logger

  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
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
      task_info = prepare_draft_task(scope, result)
      markdown = NextTaskMarkdown.render(result, scope, project, task_info)

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

  defp prepare_draft_task(scope, {:ok, requirement}) do
    requirement = Repo.preload(requirement, [:component])

    case Sessions.list_active_sessions(scope) do
      [session | _] ->
        task_attrs = %{
          session_type: requirement.satisfied_by,
          requirement_name: requirement.name,
          project_id: scope.active_project_id,
          component_id: requirement.component_id,
          component_module_name:
            case requirement.component do
              %{module_name: name} -> name
              _ -> nil
            end,
          story_id: requirement.story_id
        }

        case Sessions.prepare_task(scope, session, task_attrs) do
          {:ok, updated_session} ->
            task =
              updated_session.tasks
              |> Enum.filter(&(&1.status == :prepared))
              |> List.last()

            {session.id, task.id}

          _ ->
            nil
        end

      [] ->
        nil
    end
  end

  defp prepare_draft_task(_scope, _other), do: nil
end
