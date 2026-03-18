defmodule CodeMySpecWeb.ContentAdminLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.ContentAdmin
  alias Phoenix.PubSub

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-7xl mx-auto">
        <.header>
          ContentAdmin
          <:actions>
            <.button phx-click="trigger-sync">
              <.icon name="hero-arrow-path" /> Sync from Git
            </.button>
            <.button phx-click="push-to-client" class="btn btn-primary ml-2">
              <.icon name="hero-cloud-arrow-up" /> Push to Client
            </.button>
          </:actions>
        </.header>

        <dialog :if={@push_error_detail} id="push-error-modal" class="modal modal-open">
          <div class="modal-box w-11/12 max-w-3xl">
            <form method="dialog">
              <button
                phx-click="close-error-modal"
                class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
              >
                ✕
              </button>
            </form>
            <h3 class="font-bold text-lg mb-4">Push to Client Failed</h3>
            <div class="space-y-4">
              <div>
                <h4 class="font-semibold text-sm mb-2">Error Type:</h4>
                <p class="text-sm font-mono bg-base-200 p-2 rounded">{@push_error_detail.type}</p>
              </div>
              <div>
                <h4 class="font-semibold text-sm mb-2">Details:</h4>
                <pre class="text-xs font-mono bg-base-200 p-3 rounded overflow-x-auto whitespace-pre-wrap">{@push_error_detail.message}</pre>
              </div>
              <div :if={@push_error_detail.debug_info}>
                <h4 class="font-semibold text-sm mb-2">Debug Information:</h4>
                <pre class="text-xs font-mono bg-base-200 p-3 rounded overflow-x-auto whitespace-pre-wrap">{@push_error_detail.debug_info}</pre>
              </div>
            </div>
          </div>
          <form method="dialog" class="modal-backdrop" phx-click="close-error-modal">
            <button>close</button>
          </form>
        </dialog>

        <div class="mb-4 flex gap-2">
          <span class="badge badge-success gap-2">
            {@status_counts.success} Published
          </span>
          <span class="badge badge-error gap-2">
            {@status_counts.error} Errors
          </span>
        </div>

        <div class="mb-4 flex gap-2">
          <.input
            type="select"
            name="filter_type"
            value={@filter_type}
            phx-change="filter-type"
            options={[{"All Types", ""}, {"Blog", "blog"}, {"Page", "page"}, {"Landing", "landing"}]}
          />
          <.input
            type="select"
            name="filter_status"
            value={@filter_status}
            phx-change="filter-status"
            options={[
              {"All Status", ""},
              {"Success", "success"},
              {"Error", "error"},
              {"Pending", "pending"}
            ]}
          />
          <.button :if={@filter_type || @filter_status} phx-click="clear-filters" class="ml-2">
            Clear Filters
          </.button>
        </div>

        <.table
          id="content_admin"
          rows={@streams.content_admin}
          row_click={
            fn {_id, content_admin} -> JS.navigate(~p"/app/content_admin/#{content_admin}") end
          }
        >
          <:col :let={{_id, content_admin}} label="Slug">
            <div class="truncate max-w-sm">
              {get_metadata(content_admin, "slug") || "no-slug"}
            </div>
          </:col>
          <:col :let={{_id, content_admin}} label="Type">
            <.this_badge
              type={:content_type}
              value={atomize_type(get_metadata(content_admin, "type"))}
            />
          </:col>
          <:col :let={{_id, content_admin}} label="Status">
            <.this_badge
              type={:parse_status}
              value={content_admin.parse_status}
              title={format_parse_errors(content_admin.parse_errors)}
            />
          </:col>
          <:col :let={{_id, content_admin}} label="Published">
            {format_publish_date(get_metadata(content_admin, "publish_at"))}
          </:col>
          <:col :let={{_id, content_admin}} label="Expires">
            {format_expiry_date(get_metadata(content_admin, "expires_at"))}
          </:col>
          <:action :let={{_id, content_admin}}>
            <div class="sr-only">
              <.link navigate={~p"/app/content_admin/#{content_admin}"}>Show</.link>
            </div>
            <.link navigate={~p"/app/content_admin/#{content_admin}"}>View</.link>
          </:action>
          <:action :let={{id, content_admin}}>
            <.link
              phx-click={JS.push("delete", value: %{id: content_admin.id}) |> hide("##{id}")}
              data-confirm="Are you sure? ContentAdmin will re-sync on next Git sync."
            >
              Delete
            </.link>
          </:action>
        </.table>

        <div :if={@content_admin_count == 0} class="text-center py-12 opacity-60">
          <%= if @filter_type || @filter_status do %>
            No content_admin matches the selected filters.
          <% else %>
            No content_admin synced yet. Trigger a sync to import content_admin from your Git repository.
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      subscribe_content_admin(scope)
    end

    content_admin = ContentAdmin.list_all_content(scope)

    {:ok,
     socket
     |> assign(:page_title, "ContentAdmin")
     |> assign(:filter_type, nil)
     |> assign(:filter_status, nil)
     |> assign(:push_error_detail, nil)
     |> assign(:content_admin_count, length(content_admin))
     |> assign_status_counts(scope)
     |> stream(:content_admin, content_admin)}
  end

  @impl true
  def handle_event("filter-type", %{"filter_type" => type}, socket) do
    filter_type = if type == "", do: nil, else: type
    {:noreply, apply_filters(socket, filter_type, socket.assigns.filter_status)}
  end

  def handle_event("filter-status", %{"filter_status" => status}, socket) do
    filter_status = if status == "", do: nil, else: status
    {:noreply, apply_filters(socket, socket.assigns.filter_type, filter_status)}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, apply_filters(socket, nil, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    content_admin = ContentAdmin.get_content!(scope, id)
    # ContentAdmin doesn't have individual delete - records are replaced on sync
    # Just remove from stream for now
    {:noreply, stream_delete(socket, :content_admin, content_admin)}
  end

  def handle_event("trigger-sync", _params, socket) do
    scope = socket.assigns.current_scope

    case CodeMySpec.ContentSync.sync_to_content_admin(scope) do
      {:ok, sync_result} ->
        message = """
        Sync completed successfully!
        Total: #{sync_result.total_files} files
        Success: #{sync_result.successful}
        Errors: #{sync_result.errors}
        Duration: #{sync_result.duration_ms}ms
        """

        {:noreply, put_flash(socket, :info, message)}

      {:error, :no_active_project} ->
        {:noreply, put_flash(socket, :error, "No active project selected")}

      {:error, :project_not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      {:error, :no_docs_repo} ->
        {:noreply, put_flash(socket, :error, "Project has no docs repository configured")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Sync failed: #{inspect(reason)}")}
    end
  end

  def handle_event("push-to-client", _params, socket) do
    socket.assigns.current_scope
    |> CodeMySpec.ContentSync.push_to_client()
    |> case do
      {:ok, push_result} ->
        message = """
        Push to client completed successfully!
        Synced: #{push_result.synced_content_count} content items
        """

        {:noreply, socket |> assign(:push_error_detail, nil) |> put_flash(:info, message)}

      {:error, :no_active_project} ->
        {:noreply,
         assign_push_error(socket, "No Active Project", "No active project selected", nil)}

      {:error, :has_validation_errors} ->
        error_count = socket.assigns.status_counts.error

        {:noreply,
         assign_push_error(
           socket,
           "Validation Errors",
           "Cannot push to client because ContentAdmin has #{error_count} validation errors.",
           "Fix errors first by syncing from Git. Check the error status column in the content list."
         )}

      {:error, :project_not_found} ->
        {:noreply, assign_push_error(socket, "Project Not Found", "Project not found", nil)}

      {:error, :no_docs_repo} ->
        {:noreply,
         assign_push_error(
           socket,
           "No Docs Repository",
           "Project has no docs repository configured",
           "Update your project settings to add a docs_repo URL"
         )}

      {:error, :no_client_config} ->
        {:noreply,
         assign_push_error(
           socket,
           "Missing Client Configuration",
           "Project has no client API URL or deploy key configured",
           "Go to Project Settings and configure:\n1. Client API URL (e.g., https://client.example.com)\n2. Deploy Key (click Generate to create one)"
         )}

      {:error, {:http_error, status_code, response_body}} ->
        {:noreply,
         assign_push_error(
           socket,
           "Client API Error (HTTP #{status_code})",
           "The client appliance returned an error",
           "Status: #{status_code}\nResponse:\n#{format_response_body(response_body)}"
         )}

      {:error, {:http_request_failed, message}} ->
        {:noreply,
         assign_push_error(
           socket,
           "Connection Failed",
           "Failed to connect to client appliance",
           "Error: #{message}\n\nPossible causes:\n- Client is offline or unreachable\n- Incorrect Client API URL\n- Network/firewall issues"
         )}

      {:error, reason} ->
        {:noreply,
         assign_push_error(
           socket,
           "Unknown Error",
           "Push to client failed with an unexpected error",
           inspect(reason, pretty: true, limit: :infinity)
         )}
    end
  end

  def handle_event("close-error-modal", _params, socket) do
    {:noreply, assign(socket, :push_error_detail, nil)}
  end

  @impl true
  def handle_info({:created, %ContentAdmin.ContentAdmin{}}, socket) do
    {:noreply, reload_content_admin(socket)}
  end

  def handle_info({:updated, %ContentAdmin.ContentAdmin{}}, socket) do
    {:noreply, reload_content_admin(socket)}
  end

  def handle_info({:deleted, %ContentAdmin.ContentAdmin{}}, socket) do
    {:noreply, reload_content_admin(socket)}
  end

  def handle_info(:bulk_delete, socket) do
    {:noreply, reload_content_admin(socket)}
  end

  def handle_info({:sync_completed, _sync_result}, socket) do
    {:noreply, reload_content_admin(socket)}
  end

  defp apply_filters(socket, filter_type, filter_status) do
    scope = socket.assigns.current_scope

    content_admin = ContentAdmin.list_all_content(scope)

    # Apply filters in memory
    filtered_content_admin =
      content_admin
      |> filter_by_type(filter_type)
      |> filter_by_status(filter_status)

    socket
    |> assign(:filter_type, filter_type)
    |> assign(:filter_status, filter_status)
    |> assign(:content_admin_count, length(filtered_content_admin))
    |> stream(:content_admin, filtered_content_admin, reset: true)
  end

  defp filter_by_type(content_admin, nil), do: content_admin

  defp filter_by_type(content_admin, type) do
    Enum.filter(content_admin, fn ca ->
      content_type = get_metadata(ca, "content_type") || get_metadata(ca, "type")
      content_type == type
    end)
  end

  defp filter_by_status(content_admin, nil), do: content_admin

  defp filter_by_status(content_admin, status) do
    status_atom = String.to_existing_atom(status)
    Enum.filter(content_admin, &(&1.parse_status == status_atom))
  end

  # Helper to safely get metadata fields
  defp get_metadata(content_admin, key) do
    case content_admin.metadata do
      nil ->
        nil

      metadata when is_map(metadata) ->
        # Try both string and atom keys for flexibility
        Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))

      _ ->
        nil
    end
  end

  defp reload_content_admin(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign_status_counts(scope)
    |> apply_filters(socket.assigns.filter_type, socket.assigns.filter_status)
  end

  defp assign_status_counts(socket, scope) do
    counts = ContentAdmin.count_by_parse_status(scope)
    assign(socket, :status_counts, counts)
  end

  defp subscribe_content_admin(scope) do
    PubSub.subscribe(
      CodeMySpec.PubSub,
      "account:#{scope.active_account_id}:project:#{scope.active_project_id}:content_admin"
    )
  end

  # Helper function for badge component
  defp this_badge(assigns) do
    badge_class =
      case {assigns.type, assigns.value} do
        {:content_type, :page} -> "badge-success"
        {:content_type, :landing} -> "badge-secondary"
        {:content_type, :documentation} -> "badge-primary"
        {:content_type, :blog} -> "badge-info"
        {:parse_status, :success} -> "badge-success"
        {:parse_status, :error} -> "badge-error"
        {:parse_status, :pending} -> "badge-warning"
        _ -> "badge-ghost"
      end

    # For parse_status, show icon only. For content_type, show the type name
    display_value =
      case {assigns.type, assigns.value} do
        {:parse_status, :success} -> "✓"
        {:parse_status, :error} -> "✗"
        {:parse_status, :pending} -> "⋯"
        {:content_type, value} when is_atom(value) -> Atom.to_string(value)
        _ -> to_string(assigns.value)
      end

    title = Map.get(assigns, :title)

    assigns =
      assign(assigns, :badge_class, badge_class)
      |> assign(:display_value, display_value)
      |> assign(:title_attr, title)

    ~H"""
    <span class={"badge #{@badge_class}"} title={@title_attr}>
      {@display_value}
    </span>
    """
  end

  # Helper to convert string type to atom
  defp atomize_type("blog"), do: :blog
  defp atomize_type("page"), do: :page
  defp atomize_type("landing"), do: :landing
  defp atomize_type("documentation"), do: :documentation
  defp atomize_type(_), do: :blog

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp format_publish_date(nil), do: "Draft"

  defp format_publish_date(value) do
    case parse_datetime(value) do
      nil ->
        "Draft"

      datetime ->
        now = DateTime.utc_now()

        if DateTime.compare(datetime, now) == :gt do
          "Scheduled: #{Calendar.strftime(datetime, "%Y-%m-%d")}"
        else
          Calendar.strftime(datetime, "%Y-%m-%d")
        end
    end
  end

  defp format_expiry_date(nil), do: "Never"

  defp format_expiry_date(value) do
    case parse_datetime(value) do
      nil -> "Never"
      datetime -> Calendar.strftime(datetime, "%Y-%m-%d")
    end
  end

  defp format_parse_errors(nil), do: nil
  defp format_parse_errors(errors) when errors == %{}, do: nil

  defp format_parse_errors(errors) do
    errors
    |> Enum.map(fn {key, value} -> "#{key}: #{inspect(value)}" end)
    |> Enum.join("\n")
  end

  defp assign_push_error(socket, type, message, debug_info) do
    socket
    |> assign(:push_error_detail, %{
      type: type,
      message: message,
      debug_info: debug_info
    })
  end

  defp format_response_body(body) when is_binary(body), do: body
  defp format_response_body(body) when is_map(body), do: Jason.encode!(body, pretty: true)
  defp format_response_body(body), do: inspect(body, pretty: true)
end
