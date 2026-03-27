defmodule CodeMySpecLocalWeb.IssuesLive.Show do
  @moduledoc """
  Displays a single issue with full details.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, issue: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name, "id" => id}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      slug = project_slug(project)

      case Issues.get_issue(scope, id) do
        nil ->
          {:noreply, assign(socket, error: "Issue not found: #{id}")}

        issue ->
          {:noreply,
           assign(socket,
             project: project,
             slug: slug,
             issue: issue,
             error: nil
           )}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} role="alert" class="alert alert-error">
      <span>{@error}</span>
    </div>

    <div :if={!@error && @issue}>
      <div class="mb-4">
        <.link navigate={"/projects/#{@slug}/issues"} class="btn btn-ghost btn-sm gap-1">
          &larr; Issues
        </.link>
      </div>

      <div class="flex items-start justify-between mb-6">
        <h1 class="text-2xl font-bold">{@issue.title}</h1>
        <div class="flex gap-2">
          <span class={"badge #{status_badge(@issue.status)}"}>{@issue.status}</span>
          <span class={"badge badge-outline #{severity_badge(@issue.severity)}"}>{@issue.severity}</span>
        </div>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-6">
        <div>
          <div class="text-xs text-base-content/50 uppercase">Scope</div>
          <div>{@issue.scope}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 uppercase">Created</div>
          <div>{Calendar.strftime(@issue.inserted_at, "%b %d, %Y")}</div>
        </div>
        <div :if={@issue.story_id}>
          <div class="text-xs text-base-content/50 uppercase">Story</div>
          <.link navigate={"/projects/#{@slug}/stories/#{@issue.story_id}"} class="link link-primary">
            #{@issue.story_id}
          </.link>
        </div>
        <div :if={@issue.source_path}>
          <div class="text-xs text-base-content/50 uppercase">Source</div>
          <code class="text-sm">{@issue.source_path}</code>
        </div>
      </div>

      <div :if={@issue.description && @issue.description != ""} class="mb-6">
        <h2 class="text-lg font-semibold mb-2">Description</h2>
        <div class="bg-base-200 rounded-lg p-4 whitespace-pre-wrap text-sm">
          {@issue.description}
        </div>
      </div>

      <div :if={@issue.resolution && @issue.resolution != ""}>
        <h2 class="text-lg font-semibold mb-2">Resolution</h2>
        <div class="bg-base-200 rounded-lg p-4 whitespace-pre-wrap text-sm">
          {@issue.resolution}
        </div>
      </div>
    </div>
    """
  end

  # -- Helpers -----------------------------------------------------------------

  defp status_badge(:incoming), do: "badge-info"
  defp status_badge(:accepted), do: "badge-success"
  defp status_badge(:dismissed), do: "badge-neutral"
  defp status_badge(:resolved), do: "badge-primary"
  defp status_badge(_), do: ""

  defp severity_badge(:critical), do: "badge-error"
  defp severity_badge(:high), do: "badge-warning"
  defp severity_badge(:medium), do: "badge-info"
  defp severity_badge(:low), do: "badge-neutral"
  defp severity_badge(:info), do: "badge-ghost"
  defp severity_badge(_), do: ""

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
