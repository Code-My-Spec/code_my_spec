defmodule CodeMySpecLocalWeb.SyncLive do
  @moduledoc """
  Human interface for triggering project sync.

  Runs incremental sync to recalculate requirements, update status,
  and persist results to the database.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Issues.RemoteSync, as: IssuesRemoteSync
  alias CodeMySpec.Stories.RemoteSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       sync_status: :idle,
       sync_result: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         slug: project_slug(project),
         page_title: "#{project.name} — Sync",
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("sync", _params, socket) do
    socket = assign(socket, sync_status: :running, sync_result: nil)
    scope = socket.assigns.scope

    {stories_line, issues_line} = run_remote_syncs(scope)

    with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
      {:noreply,
       assign(socket,
         sync_status: :done,
         sync_result: [
           stories_line,
           issues_line,
           {"Files", file_result.total_files},
           {"Changed files", length(file_result.changed_paths)},
           {"Components", length(comp_result.all_components)},
           {"Changed components", length(comp_result.changed_component_ids)}
         ]
       )}
    else
      {:error, reason} ->
        Logger.error("[SyncLive] Sync failed: #{inspect(reason)}")
        {:noreply, assign(socket, sync_status: :error, sync_result: %{error: inspect(reason)})}
    end
  end

  def handle_event("purge", _params, socket) do
    scope = socket.assigns.scope

    {file_count, _} = Files.delete_removed(scope, [])
    Requirements.clear_all_project_requirements(scope)

    components = Components.list_components(scope)
    Enum.each(components, &Components.delete_component(scope, &1))

    Logger.info(
      "[SyncLive] Purged #{file_count} files, #{length(components)} components for #{scope.active_project.name}"
    )

    {:noreply,
     assign(socket,
       sync_status: :done,
       sync_result: [{"Purged", "#{file_count} files + #{length(components)} components deleted"}]
     )}
  end

  defp run_remote_syncs(scope) do
    if OAuthClient.authenticated?() do
      {
        safe_remote_sync("Stories", fn -> RemoteSync.sync(scope) end),
        safe_remote_sync("Issues", fn -> IssuesRemoteSync.sync(scope) end)
      }
    else
      {{"Stories", "skipped — not authenticated"}, {"Issues", "skipped — not authenticated"}}
    end
  end

  defp safe_remote_sync(label, fun) do
    case fun.() do
      :ok -> {label, "synced from remote"}
      {:ok, _} -> {label, "synced from remote"}
      {:error, reason} -> {label, "sync failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} section={:sync} page_title={assigns[:page_title]}>
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">Sync</h1>
          <p class="text-base-content/60 mt-1">
            Recalculate requirements, update component status, and persist results.
          </p>
        </div>

        <div class="flex flex-wrap gap-3 mb-6">
          <button
            type="button"
            phx-click="sync"
            disabled={@sync_status == :running}
            class="btn btn-primary"
          >
            <span :if={@sync_status == :running} class="loading loading-spinner loading-sm"></span>
            {if @sync_status == :running, do: "Syncing…", else: "Run Sync"}
          </button>

          <button
            type="button"
            phx-click="purge"
            disabled={@sync_status == :running}
            data-confirm="This will delete ALL components and requirements for this project. Continue?"
            class="btn btn-error btn-outline"
          >
            Purge All
          </button>
        </div>

        <div :if={@sync_status == :done && @sync_result} class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title text-lg">Sync Complete</h2>
            <table class="table table-sm">
              <tbody>
                <tr :for={{label, value} <- @sync_result}>
                  <td class="opacity-60 w-1/3">{label}</td>
                  <td class="font-mono text-sm">{value}</td>
                </tr>
              </tbody>
            </table>
            <div class="card-actions justify-end mt-2">
              <.link navigate={~p"/projects/#{@slug}/requirements"} class="btn btn-sm btn-ghost">
                View requirements →
              </.link>
            </div>
          </div>
        </div>

        <div :if={@sync_status == :error && @sync_result} role="alert" class="alert alert-error">
          <div>
            <h2 class="font-bold">Sync Failed</h2>
            <pre class="text-xs mt-2 whitespace-pre-wrap">{@sync_result.error}</pre>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
