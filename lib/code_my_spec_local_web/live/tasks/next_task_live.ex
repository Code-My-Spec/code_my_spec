defmodule CodeMySpecLocalWeb.Tasks.NextTaskLive do
  @moduledoc """
  Preview of what the agent sees from `get_next_requirement`.
  """
  use CodeMySpecLocalWeb, :live_view

  require Logger

  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       markdown: nil,
       error: nil,
       sync_status: :idle,
       sync_error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:noreply,
       socket
       |> assign(
         project: project,
         scope: scope,
         page_title: "#{project.name} — Next Task",
         error: nil
       )
       |> recompute()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("sync", _params, socket) do
    scope = socket.assigns.scope
    socket = assign(socket, sync_status: :running, sync_error: nil)

    with {:ok, _file_result} <- FileSync.sync(scope, base_dir: scope.cwd, embed: false),
         {:ok, _comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
      {:noreply,
       socket
       |> assign(sync_status: :done)
       |> recompute()}
    else
      {:error, reason} ->
        Logger.error("[NextTaskLive] Sync failed: #{inspect(reason)}")
        {:noreply, assign(socket, sync_status: :error, sync_error: inspect(reason))}
    end
  end

  defp recompute(%{assigns: %{scope: nil}} = socket), do: socket

  defp recompute(%{assigns: %{scope: scope}} = socket) do
    markdown =
      case RequirementGraph.next_actionable(scope) do
        [] -> "# All requirements satisfied\n\nNo actionable tasks remain."
        nodes -> RequirementsMapper.format_next_requirements(nodes)
      end

    assign(socket, markdown: markdown)
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
        <div class="mb-6 flex justify-between items-start gap-4">
          <div>
            <h1 class="text-3xl font-bold">Next Task</h1>
            <p class="text-base-content/60 mt-1">Preview of what the agent sees from <code class="kbd kbd-sm">get_next_requirement</code>.</p>
          </div>
          <button
            type="button"
            phx-click="sync"
            data-test="sync-button"
            disabled={@sync_status == :running}
            class="btn btn-secondary shrink-0"
            title="Refresh files + components (skips embeddings)"
          >
            <span :if={@sync_status == :running} class="loading loading-spinner loading-sm"></span>
            {if @sync_status == :running, do: "Syncing…", else: "Sync"}
          </button>
        </div>

        <div :if={@sync_status == :error} role="alert" class="alert alert-error alert-soft mb-4">
          <span>Sync failed: <code class="font-mono text-xs">{@sync_error}</code></span>
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
