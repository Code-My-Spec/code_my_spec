defmodule CodeMySpecLocalWeb.FilesLive do
  @moduledoc """
  Files projection viewer.

  Sibling surface to `/sync`: lists every tracked File row for the project so
  the founder can see exactly which files are out of sync with disk without
  reading server logs or DB rows. Re-sync is delegated to the same FileSync
  + ComponentSync pipeline that the `/sync` page drives.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Issues.RemoteSync, as: IssuesRemoteSync
  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  require Logger

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       page: 1,
       filter: :all,
       result: nil,
       sync_status: :idle,
       sync_result: nil,
       watcher_event_count: 0,
       watcher_last_event: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name} = params, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        page = parse_page(params["page"])
        filter = parse_filter(params["filter"])
        result = Files.list_files_paginated(scope, page: page, per_page: @per_page, filter: filter)

        if connected?(socket) and socket.assigns.project != project do
          ProjectSync.subscribe(scope)
        end

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           slug: project_slug(project),
           page: page,
           filter: filter,
           result: result,
           page_title: "#{project.name} — Files",
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:watcher_synced, %{path: path, at: at}}, socket) do
    socket =
      if socket.assigns.scope do
        result =
          Files.list_files_paginated(socket.assigns.scope,
            page: socket.assigns.page,
            per_page: @per_page,
            filter: socket.assigns.filter
          )

        assign(socket, result: result)
      else
        socket
      end

    {:noreply,
     assign(socket,
       watcher_event_count: socket.assigns.watcher_event_count + 1,
       watcher_last_event: %{path: path, at: at}
     )}
  end

  @impl true
  def handle_event("sync", _params, socket), do: do_sync(socket, embed: false)
  def handle_event("embed", _params, socket), do: do_embed(socket)

  def handle_event("purge", _params, socket) do
    scope = socket.assigns.scope

    {file_count, _} = Files.delete_removed(scope, [])
    Requirements.clear_all_project_requirements(scope)

    components = Components.list_components(scope)
    Enum.each(components, &Components.delete_component(scope, &1))

    Logger.info(
      "[FilesLive] Purged #{file_count} files, #{length(components)} components for #{scope.active_project.name}"
    )

    result =
      Files.list_files_paginated(scope,
        page: 1,
        per_page: @per_page,
        filter: socket.assigns.filter
      )

    {:noreply,
     assign(socket,
       result: result,
       page: 1,
       sync_status: :done,
       sync_result: [{"Purged", "#{file_count} files + #{length(components)} components deleted"}]
     )}
  end

  defp do_sync(socket, opts) do
    scope = socket.assigns.scope
    embed? = Keyword.get(opts, :embed, false)
    socket = assign(socket, sync_status: :running, sync_result: nil)

    remote_lines = run_remote_syncs(scope)

    with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd, embed: embed?),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
      result =
        Files.list_files_paginated(scope,
          page: socket.assigns.page,
          per_page: @per_page,
          filter: socket.assigns.filter
        )

      {:noreply,
       assign(socket,
         result: result,
         sync_status: :done,
         sync_result:
           remote_lines ++
             [
               {"Files", file_result.total_files},
               {"Changed files", length(file_result.changed_paths)},
               {"Components", length(comp_result.all_components)},
               {"Changed components", length(comp_result.changed_component_ids)}
             ]
       )}
    else
      {:error, reason} ->
        Logger.error("[FilesLive] Sync failed: #{inspect(reason)}")

        {:noreply,
         assign(socket, sync_status: :error, sync_result: %{error: inspect(reason)})}
    end
  end

  defp do_embed(socket) do
    scope = socket.assigns.scope
    socket = assign(socket, sync_status: :running, sync_result: nil)

    {:ok, result} = FileSync.embed_only(scope)

    {:noreply,
     assign(socket,
       sync_status: :done,
       sync_result: [
         {"Embedded", result.embedded},
         {"Elapsed", "#{result.elapsed_ms}ms"}
       ]
     )}
  end

  defp run_remote_syncs(scope) do
    if OAuthClient.authenticated?() do
      [
        safe_remote_sync("Issues", fn -> IssuesRemoteSync.sync(scope) end)
      ]
    else
      [
        {"Issues", "skipped — not authenticated"}
      ]
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
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:files}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project && @result}>
        <div
          data-test="watcher-activity"
          data-event-count={@watcher_event_count}
          data-last-path={@watcher_last_event && @watcher_last_event.path}
          data-last-at={@watcher_last_event && DateTime.to_iso8601(@watcher_last_event.at)}
          class="hidden"
        ></div>
        <div class="mb-6 flex justify-between items-start">
          <div>
            <h1 class="text-3xl font-bold">Files</h1>
            <p class="text-base-content/60 mt-1">
              Every tracked file in this project, projected from disk into the DB.
              Use this view to spot drift between the filesystem and the projection.
            </p>
            <div
              :if={@watcher_last_event}
              data-test="watcher-last-event"
              class="text-xs text-base-content/50 mt-1 font-mono"
            >
              Watcher: last event {@watcher_last_event.path} ({@watcher_event_count} total)
            </div>
          </div>
          <div class="flex flex-row gap-2 shrink-0">
            <button
              type="button"
              phx-click="sync"
              data-test="sync-button"
              disabled={@sync_status == :running}
              class="btn btn-primary"
              title="Walk filesystem and project files into the DB (no embeddings)"
            >
              <span :if={@sync_status == :running} class="loading loading-spinner loading-sm"></span>
              {if @sync_status == :running, do: "Syncing…", else: "Sync"}
            </button>
            <button
              type="button"
              phx-click="embed"
              data-test="embed-button"
              disabled={@sync_status == :running}
              class="btn btn-secondary"
              title="Run embedding hooks against currently-tracked files (slow)"
            >
              <span :if={@sync_status == :running} class="loading loading-spinner loading-sm"></span>
              Embed
            </button>
            <button
              type="button"
              phx-click="purge"
              data-test="purge-button"
              disabled={@sync_status == :running}
              data-confirm="This will delete ALL components and requirements for this project. Continue?"
              class="btn btn-error btn-outline"
            >
              Purge All
            </button>
          </div>
        </div>

        <div
          :if={@sync_status == :done && is_list(@sync_result)}
          role="alert"
          class="alert alert-success alert-soft mb-6"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="h-6 w-6 shrink-0 stroke-current"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <div>
            <h3 class="font-bold">Sync Complete</h3>
            <ul class="mt-1 text-sm space-y-0.5">
              <li :for={{label, value} <- @sync_result}>
                <span class="opacity-70">{label}:</span>
                <span class="font-mono">{value}</span>
              </li>
            </ul>
          </div>
        </div>

        <div
          :if={@sync_status == :error && is_map(@sync_result)}
          role="alert"
          class="alert alert-error alert-soft mb-6"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="h-6 w-6 shrink-0 stroke-current"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <div>
            <h3 class="font-bold">Sync Failed</h3>
            <pre class="text-xs mt-2 whitespace-pre-wrap">{@sync_result.error}</pre>
          </div>
        </div>

        <div class="flex gap-2 mb-4">
          <.link
            patch={files_path(@slug, page: 1, filter: :all)}
            data-test="filter-all"
            class={"btn btn-sm " <> if(@filter == :all, do: "btn-primary", else: "btn-ghost")}
          >
            All ({@result.unfiltered_count})
          </.link>
          <.link
            patch={files_path(@slug, page: 1, filter: :invalid)}
            data-test="filter-invalid"
            class={"btn btn-sm " <> if(@filter == :invalid, do: "btn-error", else: "btn-ghost")}
          >
            Invalid only ({@result.invalid_count})
          </.link>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-zebra table-sm" data-test="files-table">
            <thead>
              <tr>
                <th>Path</th>
                <th>Role</th>
                <th>Validity</th>
                <th>Component</th>
                <th>Size</th>
                <th>mtime</th>
                <th>Fingerprint</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={file <- @result.files}
                data-test="file-row"
                data-file-path={file.path}
              >
                <td class="font-mono text-xs" data-test="file-path">{file.path}</td>
                <td data-test="file-role">{format_role(file.role)}</td>
                <td data-test="file-validity" data-validity={validity_label(file)}>
                  <.validity_badge file={file} />
                </td>
                <td>
                  <.component_cell file={file} slug={@slug} />
                </td>
                <td class="font-mono text-xs">{file.size}</td>
                <td
                  class="font-mono text-xs"
                  data-test="file-mtime"
                  data-mtime={raw_mtime(file.mtime)}
                >{format_mtime(file.mtime)}</td>
                <td
                  class="font-mono text-xs"
                  data-test="file-fingerprint"
                  data-fingerprint={file.fingerprint}
                  title={file.fingerprint}
                >
                  {format_fingerprint(file.fingerprint)}
                </td>
              </tr>
              <tr :if={@result.files == []}>
                <td colspan="7" class="text-center opacity-60 py-8">
                  No files match the current filter.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <nav
          :if={@result.total_pages > 1}
          data-test="pagination"
          class="flex justify-between items-center mt-4"
        >
          <span class="text-sm opacity-60">
            Page {@result.page} of {@result.total_pages} ({@result.total_count} files)
          </span>
          <div class="join">
            <.link
              :if={@result.page > 1}
              patch={files_path(@slug, page: @result.page - 1, filter: @filter)}
              data-test="prev-page"
              class="join-item btn btn-sm"
            >
              ← Prev
            </.link>
            <.link
              :if={@result.page < @result.total_pages}
              patch={files_path(@slug, page: @result.page + 1, filter: @filter)}
              data-test="next-page"
              class="join-item btn btn-sm"
            >
              Next →
            </.link>
          </div>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  attr :file, :any, required: true

  defp validity_badge(assigns) do
    ~H"""
    <span :if={@file.valid == true} class="badge badge-success badge-sm">valid</span>
    <span :if={@file.valid == false} class="badge badge-error badge-sm">invalid</span>
    <span :if={is_nil(@file.valid)} class="badge badge-ghost badge-sm">unvalidated</span>
    """
  end

  attr :file, :any, required: true
  attr :slug, :string, required: true

  defp component_cell(assigns) do
    ~H"""
    <.link
      :if={@file.component}
      navigate={~p"/projects/#{@slug}/components/#{@file.component.id}"}
      data-test="file-component-link"
      class="link link-primary text-sm"
    >
      {@file.component.module_name}
    </.link>
    <span :if={!@file.component} data-test="file-unowned" class="opacity-50 italic text-sm">
      (unowned)
    </span>
    """
  end

  defp validity_label(%{valid: true}), do: "valid"
  defp validity_label(%{valid: false}), do: "invalid"
  defp validity_label(_), do: "unvalidated"

  defp format_role(role) when is_atom(role), do: Atom.to_string(role)
  defp format_role(role) when is_binary(role), do: role
  defp format_role(_), do: ""

  defp format_mtime(nil), do: "—"

  defp format_mtime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_mtime(other), do: inspect(other)

  defp raw_mtime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp raw_mtime(_), do: nil

  defp format_fingerprint(nil), do: "—"
  defp format_fingerprint(fp) when is_binary(fp), do: String.slice(fp, 0, 12)
  defp format_fingerprint(_), do: ""

  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp parse_filter("invalid"), do: :invalid
  defp parse_filter(_), do: :all

  defp files_path(slug, opts) do
    page = Keyword.get(opts, :page, 1)
    filter = Keyword.get(opts, :filter, :all)

    base = "/projects/#{slug}/files"

    params = []
    params = if page > 1, do: [{"page", page} | params], else: params
    params = if filter == :invalid, do: [{"filter", "invalid"} | params], else: params

    case params do
      [] -> base
      _ -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end
end
