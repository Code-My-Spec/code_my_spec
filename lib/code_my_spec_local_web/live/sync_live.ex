defmodule CodeMySpecLocalWeb.SyncLive do
  @moduledoc """
  Human interface for triggering project sync.

  Runs incremental sync to recalculate requirements, update status,
  and persist results to the database.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
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
      {:noreply, assign(socket, project: project, scope: scope, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("sync", _params, socket) do
    socket = assign(socket, sync_status: :running, sync_result: nil)
    scope = socket.assigns.scope

    case Sync.incremental_sync(scope, base_dir: scope.cwd, write_status: true) do
      {:ok, result} ->
        {:noreply,
         assign(socket,
           sync_status: :done,
           sync_result: summarize_result(result)
         )}

      {:error, reason} ->
        Logger.error("[SyncLive] Sync failed: #{inspect(reason)}")

        {:noreply,
         assign(socket,
           sync_status: :error,
           sync_result: %{error: inspect(reason)}
         )}
    end
  end

  def handle_event("purge", _params, socket) do
    scope = socket.assigns.scope

    # Delete all requirements (project, story, component)
    Requirements.clear_all_project_requirements(scope)

    # Delete all components
    components = Components.list_components(scope)
    Enum.each(components, &Components.delete_component(scope, &1))

    Logger.info("[SyncLive] Purged #{length(components)} components and all requirements for #{scope.active_project.name}")

    {:noreply,
     assign(socket,
       sync_status: :done,
       sync_result: [{"Purged", "#{length(components)} components + all requirements deleted"}]
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171; padding: 24px;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={!@error && @project}>
      <h1>{@project.name || "Project"} — Sync</h1>
      <p style="color: #94a3b8; margin-bottom: 24px;">
        Recalculate requirements, update component status, and persist results.
      </p>

      <div style="display: flex; gap: 12px;">
        <button
          phx-click="sync"
          disabled={@sync_status == :running}
          style={"padding: 8px 20px; border-radius: 6px; border: none; cursor: pointer; font-size: 14px; " <>
            if(@sync_status == :running, do: "background: #334155; color: #64748b;", else: "background: #4ade80; color: #0f172a; font-weight: 600;")}
        >
          {case @sync_status do
            :running -> "Syncing..."
            _ -> "Run Sync"
          end}
        </button>

        <button
          phx-click="purge"
          disabled={@sync_status == :running}
          data-confirm="This will delete ALL components and requirements for this project. Continue?"
          style={"padding: 8px 20px; border-radius: 6px; border: none; cursor: pointer; font-size: 14px; " <>
            if(@sync_status == :running, do: "background: #334155; color: #64748b;", else: "background: #f87171; color: #fff; font-weight: 600;")}
        >
          Purge All
        </button>
      </div>

      <div :if={@sync_status == :done && @sync_result} style="margin-top: 24px;">
        <h2>Sync Complete</h2>
        <table class="checklist">
          <tr :for={{label, value} <- @sync_result} class="done">
            <td style="color: #94a3b8; padding: 6px 8px;">{label}</td>
            <td style="padding: 6px 8px;">{value}</td>
          </tr>
        </table>
        <a href={"/projects/#{project_slug(@project)}/requirements"} style="display: inline-block; margin-top: 16px;">
          View requirements &rarr;
        </a>
      </div>

      <div :if={@sync_status == :error && @sync_result} style="margin-top: 24px; color: #f87171;">
        <h2>Sync Failed</h2>
        <pre>{@sync_result.error}</pre>
      </div>
    </div>
    """
  end

  defp summarize_result(result) do
    [
      {"Components", Map.get(result, :all_components, []) |> length()},
      {"Changed", Map.get(result, :changed_ids, []) |> length()},
      {"Requirements updated", Map.get(result, :requirements_updated, 0)}
    ]
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
