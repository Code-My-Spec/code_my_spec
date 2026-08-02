defmodule CodeMySpecLocalWeb.ContentLive do
  @moduledoc """
  Local-first content publishing admin (story 712).

  The CLI/local surface for the editorial workflow: point at a content
  directory on disk, sync (parse markdown + frontmatter into the local
  snapshot), review per-file parse status, then publish to the user's own S3
  buckets and trigger the deployed client. Everything renders from the local
  snapshot — no SaaS round-trip. Full per-file content lives on the detail
  page (`ContentLive.Show`), not in the table.
  """
  use CodeMySpecLocalWeb, :live_view

  import CodeMySpecLocalWeb.ContentLive.Helpers

  alias CodeMySpec.ContentPublishing
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       projects: Projects.list_local_projects(),
       project: nil,
       slug: nil,
       scope: nil,
       current_scope: nil,
       rows: [],
       counts: %{success: 0, error: 0},
       last_synced_at: nil,
       image_synced: 0,
       image_failed: 0,
       publish_error: nil,
       publish_sync_id: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load(name) do
      {:ok, project, scope} ->
        {:noreply,
         socket
         |> assign(project: project, slug: project_slug(project), scope: scope, current_scope: scope)
         |> reload()}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save-settings", %{"settings" => attrs}, socket) do
    case Projects.update_project(socket.assigns.scope, socket.assigns.project, attrs) do
      {:ok, project} ->
        {:noreply, socket |> put_flash(:info, "Settings saved") |> reassign(project)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, settings_error_message(changeset))}
    end
  end

  def handle_event("save-source", %{"source" => %{"path" => path}}, socket) do
    {:ok, project} =
      Projects.update_project(socket.assigns.scope, socket.assigns.project, %{
        "content_source_path" => path
      })

    {:noreply, socket |> put_flash(:info, "Source directory set") |> reassign(project)}
  end

  def handle_event("sync", _params, socket) do
    case ContentPublishing.sync(socket.assigns.scope) do
      {:ok, counts} ->
        {:noreply,
         socket
         |> reload()
         |> assign(
           image_synced: Map.get(counts, :images_synced, 0),
           image_failed: Map.get(counts, :images_failed, 0)
         )}

      {:error, :no_source_path} ->
        {:noreply, put_flash(socket, :error, "Set a content source directory first")}
    end
  end

  def handle_event("publish", _params, socket) do
    case ContentPublishing.publish(socket.assigns.scope) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(publish_error: nil, publish_sync_id: result.sync_id)
         |> put_flash(:info, publish_message(result))
         |> reload()}

      {:error, %{message: message}} ->
        {:noreply,
         socket |> assign(publish_error: message, publish_sync_id: nil) |> put_flash(:error, message)}

      {:error, reason} ->
        {:noreply, assign(socket, publish_error: inspect(reason), publish_sync_id: nil)}
    end
  end

  defp publish_message(%{total: total} = result) do
    breakdown =
      result
      |> Map.get(:counts, %{})
      |> Enum.sort()
      |> Enum.map_join(", ", fn {type, n} -> "#{n} #{type}" end)

    base = "Published #{total} #{if total == 1, do: "item", else: "items"}"
    if breakdown == "", do: base, else: "#{base} (#{breakdown})"
  end

  defp settings_error_message(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
        end)
      end)

    format_errors(%{message: "Couldn't save settings", errors: errors})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:content}
      page_title="Content"
    >
      <div :if={@project}>
        <div class="mb-6 flex justify-between items-start gap-4">
          <div>
            <h1 class="text-3xl font-bold">Content</h1>
            <p class="text-base-content/60 mt-1">
              Parse content from disk, review parse status, then publish to your S3 buckets
              and trigger the deployed client.
            </p>
            <div
              :if={@last_synced_at}
              data-test="last-sync-at"
              class="text-xs text-base-content/50 mt-1 font-mono"
            >
              Last sync: {@last_synced_at}
            </div>
          </div>
          <div class="flex flex-row gap-2 shrink-0">
            <button type="button" phx-click="sync" data-test="sync-button" class="btn btn-primary">
              Re-sync
            </button>
            <button type="button" phx-click="publish" data-test="publish-button" class="btn btn-secondary">
              Publish
            </button>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 mb-4">
          <span class="badge badge-success badge-lg" data-test="content-summary">
            {@counts.success} success, {@counts.error} error
          </span>
          <span class="badge badge-ghost badge-lg" data-test="image-summary">
            {@image_synced} image synced, {@image_failed} failed
          </span>
        </div>

        <div :if={@publish_error} role="alert" class="alert alert-error alert-soft mb-4" data-test="publish-error">
          <span>{@publish_error}</span>
        </div>
        <div :if={@publish_sync_id} role="alert" class="alert alert-success alert-soft mb-4" data-test="publish-sync-id">
          <span>Published — sync {@publish_sync_id}</span>
        </div>

        <details class="collapse collapse-arrow bg-base-200 mb-6">
          <summary class="collapse-title text-sm font-semibold">Source &amp; publishing settings</summary>
          <div class="collapse-content space-y-4">
            <form data-test="content-source-form" phx-submit="save-source" class="flex gap-2 items-end">
              <label class="form-control flex-1">
                <span class="label-text text-xs">Content source directory</span>
                <input
                  type="text"
                  name="source[path]"
                  value={@project.content_source_path}
                  class="input input-bordered input-sm w-full font-mono"
                  placeholder=".code_my_spec/content"
                />
              </label>
              <button type="submit" class="btn btn-sm">Set source</button>
            </form>

            <form data-test="content-settings-form" phx-submit="save-settings" class="grid sm:grid-cols-2 gap-3">
              <label class="form-control">
                <span class="label-text text-xs">Image bucket</span>
                <input type="text" name="settings[image_bucket]" value={@project.image_bucket} class="input input-bordered input-sm" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">Images host</span>
                <input type="text" name="settings[images_host]" value={@project.images_host} class="input input-bordered input-sm" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">Content bucket</span>
                <input type="text" name="settings[content_bucket]" value={@project.content_bucket} class="input input-bordered input-sm" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">Client API URL</span>
                <input type="text" name="settings[client_api_url]" value={@project.client_api_url} class="input input-bordered input-sm" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">AWS access key ID</span>
                <input type="password" name="settings[aws_access_key_id]" value={@project.aws_access_key_id} class="input input-bordered input-sm" autocomplete="off" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">AWS secret access key</span>
                <input type="password" name="settings[aws_secret_access_key]" value={@project.aws_secret_access_key} class="input input-bordered input-sm" autocomplete="off" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">AWS region</span>
                <input type="text" name="settings[aws_region]" value={@project.aws_region} class="input input-bordered input-sm" placeholder="us-east-1" />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">Deploy key</span>
                <input type="password" name="settings[deploy_key]" value={@project.deploy_key} class="input input-bordered input-sm" autocomplete="off" />
              </label>
              <div class="flex items-end">
                <button type="submit" class="btn btn-sm">Save settings</button>
              </div>
            </form>
          </div>
        </details>

        <table class="table table-zebra table-sm" data-test="content-table">
          <thead>
            <tr>
              <th>Slug</th>
              <th>Type</th>
              <th>Status</th>
              <th>Published</th>
              <th>Expires</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              data-test={"content-row-#{filename(row)}"}
              data-parse-status={to_string(row.parse_status)}
            >
              <td class="font-mono text-xs">{slug(row)}</td>
              <td><span class="badge badge-ghost badge-sm">{content_type(row)}</span></td>
              <td>
                <span class={["badge badge-sm", status_class(row.parse_status)]}>
                  {to_string(row.parse_status)}
                </span>
                <div
                  :if={row.parse_status == :error}
                  data-test={"content-parse-error-#{filename(row)}"}
                  class="text-xs text-error mt-1 max-w-xs truncate"
                  title={format_errors(row.parse_errors)}
                >
                  {format_errors(row.parse_errors)}
                </div>
              </td>
              <td class="font-mono text-xs">{row.metadata["publish_at"] || "—"}</td>
              <td class="font-mono text-xs">{row.metadata["expires_at"] || "never"}</td>
              <td>
                <.link
                  navigate={~p"/app/projects/#{@slug}/content/#{row.id}"}
                  data-test={"content-row-link-#{filename(row)}"}
                  class="link link-primary text-xs"
                >
                  View
                </.link>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="6" class="text-center opacity-60 py-8">
                No content yet. Set a source directory and click Re-sync.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  # -- internals --

  defp load(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp reassign(socket, project) do
    {:ok, scope} = Scope.for_local_project(project)

    socket
    |> assign(project: project, slug: project_slug(project), scope: scope, current_scope: scope)
    |> reload()
  end

  defp reload(socket) do
    scope = socket.assigns.scope

    assign(socket,
      rows: ContentPublishing.list_snapshot(scope),
      counts: ContentPublishing.counts(scope),
      last_synced_at: ContentPublishing.last_synced_at(scope)
    )
  end
end
