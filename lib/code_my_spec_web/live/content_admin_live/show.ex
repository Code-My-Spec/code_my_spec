defmodule CodeMySpecWeb.ContentAdminLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.ContentAdmin
  alias Phoenix.PubSub

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        <.link navigate={~p"/app/content_admin"} class="link link-primary">
          ← Back to ContentAdmin
        </.link>
      </.header>

      <div class="mt-6">
        <div class="flex items-center gap-3 mb-4">
          <h1 class="text-3xl font-bold">
            {get_in(@content_admin.metadata, ["title"]) || get_in(@content_admin.metadata, ["slug"]) ||
              "Untitled"}
          </h1>
          <.this_badge
            type={:content_type}
            value={
              get_in(@content_admin.metadata, ["content_type"]) ||
                get_in(@content_admin.metadata, ["type"]) || "unknown"
            }
          />
          <.this_badge type={:parse_status} value={@content_admin.parse_status} />
        </div>

        <div class="grid grid-cols-2 gap-4 mb-6 p-4 bg-base-200 rounded-box">
          <div>
            <span class="font-semibold">Slug:</span>
            <span class="ml-2">{get_in(@content_admin.metadata, ["slug"]) || "no-slug"}</span>
          </div>
          <div>
            <span class="font-semibold">Type:</span>
            <span class="ml-2">
              <.this_badge
                type={:content_type}
                value={
                  get_in(@content_admin.metadata, ["content_type"]) ||
                    get_in(@content_admin.metadata, ["type"]) || "unknown"
                }
              />
            </span>
          </div>
          <div>
            <span class="font-semibold">Status:</span>
            <span class="ml-2">
              <.this_badge type={:parse_status} value={@content_admin.parse_status} />
            </span>
          </div>
          <div>
            <span class="font-semibold">Protected:</span>
            <span class="ml-2">
              <.this_badge
                type={:protected}
                value={get_in(@content_admin.metadata, ["protected"]) || false}
              />
            </span>
          </div>
          <div>
            <span class="font-semibold">Published:</span>
            <span class="ml-2">
              {format_publish_date(
                parse_datetime_from_metadata(get_in(@content_admin.metadata, ["publish_at"]))
              )}
            </span>
          </div>
          <div>
            <span class="font-semibold">Expires:</span>
            <span class="ml-2">
              {format_expiry_date(
                parse_datetime_from_metadata(get_in(@content_admin.metadata, ["expires_at"]))
              )}
            </span>
          </div>
          <div>
            <span class="font-semibold">Created:</span>
            <span class="ml-2">{format_datetime(@content_admin.inserted_at)}</span>
          </div>
          <div>
            <span class="font-semibold">Updated:</span>
            <span class="ml-2">{format_datetime(@content_admin.updated_at)}</span>
          </div>
        </div>

        <div :if={@content_admin.parse_status == :error} class="alert alert-error mb-6">
          <div>
            <h2 class="text-lg font-semibold mb-2">Parse Errors</h2>
            <pre class="text-sm whitespace-pre-wrap">{format_parse_errors(@content_admin.parse_errors)}</pre>
            <p class="mt-2 text-sm">
              Fix these errors in the Git repository and re-sync.
            </p>
          </div>
        </div>

        <details class="mb-6">
          <summary class="cursor-pointer font-semibold text-lg mb-2">SEO Metadata</summary>
          <div class="pl-4 space-y-2">
            <div :if={get_in(@content_admin.metadata, ["meta_title"])}>
              <span class="font-semibold">Meta Title:</span>
              <span class="ml-2">{get_in(@content_admin.metadata, ["meta_title"])}</span>
            </div>
            <div :if={get_in(@content_admin.metadata, ["meta_description"])}>
              <span class="font-semibold">Meta Description:</span>
              <span class="ml-2">{get_in(@content_admin.metadata, ["meta_description"])}</span>
            </div>
            <div :if={get_in(@content_admin.metadata, ["og_title"])}>
              <span class="font-semibold">OG Title:</span>
              <span class="ml-2">{get_in(@content_admin.metadata, ["og_title"])}</span>
            </div>
            <div :if={get_in(@content_admin.metadata, ["og_description"])}>
              <span class="font-semibold">OG Description:</span>
              <span class="ml-2">{get_in(@content_admin.metadata, ["og_description"])}</span>
            </div>
            <div :if={get_in(@content_admin.metadata, ["og_image"])}>
              <span class="font-semibold">OG Image:</span>
              <div class="ml-2 mt-2">
                <img
                  src={get_in(@content_admin.metadata, ["og_image"])}
                  alt="OG Image"
                  class="max-w-md border border-base-300"
                />
              </div>
            </div>
          </div>
        </details>

        <div class="mb-6">
          <h2 class="text-lg font-semibold mb-2">Tags</h2>
          <div :if={Enum.empty?(@tags)} class="opacity-60">No tags</div>
          <div :if={!Enum.empty?(@tags)} class="flex gap-2">
            <span :for={tag <- @tags} class="badge badge-ghost">
              {tag.name}
            </span>
          </div>
        </div>

        <div class="mb-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">ContentAdmin</h2>
            <div class="btn-group">
              <.button
                phx-click="toggle-view"
                class={if @show_raw, do: "btn-ghost", else: "btn-primary"}
              >
                Processed
              </.button>
              <.button
                phx-click="toggle-view"
                class={if @show_raw, do: "btn-primary", else: "btn-ghost"}
              >
                Raw
              </.button>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <%= if @show_raw do %>
                <pre class="text-sm whitespace-pre-wrap font-mono bg-base-200 p-4 rounded overflow-x-auto">{@content_admin.processed_content}</pre>
              <% else %>
                <%= if @content_admin.processed_content do %>
                  <div class="prose max-w-none">
                    {raw(@content_admin.processed_content)}
                  </div>
                <% else %>
                  <div class="opacity-60 italic">
                    <%= if String.ends_with?(get_in(@content_admin.metadata, ["slug"]) || "", ".heex") do %>
                      HEEx templates are rendered at request time. View raw to see template.
                    <% else %>
                      No processed content available.
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex gap-4">
          <.button
            phx-click="delete"
            data-confirm="Are you sure? ContentAdmin will re-sync on next Git sync."
            class="btn-error"
          >
            Delete ContentAdmin
          </.button>
          <.link
            :if={is_published?(@content_admin)}
            navigate={public_url(@content_admin)}
            class="btn btn-success"
          >
            View Public
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    content_admin = ContentAdmin.get_content!(scope, id)
    # ContentAdmin doesn't have tags - that's for Content
    tags = []

    if connected?(socket) do
      subscribe_content_admin(scope)
    end

    title =
      get_in(content_admin.metadata, ["title"]) || get_in(content_admin.metadata, ["slug"]) ||
        "Untitled"

    {:ok,
     socket
     |> assign(:page_title, title)
     |> assign(:content_admin, content_admin)
     |> assign(:tags, tags)
     |> assign(:show_raw, false)}
  end

  @impl true
  def handle_event("toggle-view", _params, socket) do
    {:noreply, assign(socket, :show_raw, !socket.assigns.show_raw)}
  end

  def handle_event("delete", _params, socket) do
    # Note: ContentAdmin doesn't have individual delete - records are replaced on sync
    {:noreply,
     socket
     |> put_flash(:info, "ContentAdmin deleted. Will re-sync on next Git sync.")
     |> push_navigate(to: ~p"/app/content_admin")}
  end

  @impl true
  def handle_info({:updated, %ContentAdmin.ContentAdmin{id: id}}, socket)
      when id == socket.assigns.content_admin.id do
    scope = socket.assigns.current_scope
    content_admin = ContentAdmin.get_content!(scope, id)

    {:noreply,
     socket
     |> assign(:content_admin, content_admin)}
  end

  def handle_info({:deleted, %ContentAdmin.ContentAdmin{id: id}}, socket)
      when id == socket.assigns.content_admin.id do
    {:noreply,
     socket
     |> put_flash(:info, "ContentAdmin was deleted")
     |> push_navigate(to: ~p"/app/content_admin")}
  end

  def handle_info({:sync_completed, _sync_result}, socket) do
    scope = socket.assigns.current_scope

    case ContentAdmin.get_content!(scope, socket.assigns.content_admin.id) do
      content_admin ->
        {:noreply,
         socket
         |> assign(:content_admin, content_admin)}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:info, "ContentAdmin was removed during sync")
       |> push_navigate(to: ~p"/app/content_admin")}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp subscribe_content_admin(scope) do
    PubSub.subscribe(
      CodeMySpec.PubSub,
      "account:#{scope.active_account_id}:project:#{scope.active_project_id}:content_admin"
    )
  end

  defp this_badge(assigns) do
    badge_class =
      case {assigns.type, assigns.value} do
        {:content_type, :blog} -> "badge-info"
        {:content_type, :page} -> "badge-success"
        {:content_type, :landing} -> "badge-secondary"
        {:content_type, :documentation} -> "badge-primary"
        {:parse_status, :success} -> "badge-success"
        {:parse_status, :error} -> "badge-error"
        {:parse_status, :pending} -> "badge-warning"
        {:protected, true} -> "badge-warning"
        {:protected, false} -> "badge-ghost"
        _ -> "badge-ghost"
      end

    icon =
      case {assigns.type, assigns.value} do
        {:parse_status, :success} -> " "
        {:parse_status, :error} -> " "
        {:parse_status, :pending} -> "� "
        {:protected, true} -> "= "
        {:protected, false} -> "= "
        _ -> ""
      end

    display_value =
      case {assigns.type, assigns.value} do
        {:protected, true} -> "Protected"
        {:protected, false} -> "Public"
        _ -> assigns.value
      end

    assigns =
      assign(assigns, :badge_class, badge_class)
      |> assign(:icon, icon)
      |> assign(:display_value, display_value)

    ~H"""
    <span class={"badge #{@badge_class}"}>
      {@icon}{@display_value}
    </span>
    """
  end

  defp format_publish_date(nil), do: "Not published"

  defp format_publish_date(datetime) do
    now = DateTime.utc_now()

    if DateTime.compare(datetime, now) == :gt do
      "Scheduled: #{Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")}"
    else
      Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp format_expiry_date(nil), do: "Never"
  defp format_expiry_date(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_parse_errors(nil), do: "No error details available"
  defp format_parse_errors(errors) when errors == %{}, do: "No error details available"

  defp format_parse_errors(errors) do
    Enum.map_join(errors, "\n", fn {key, value} -> "#{key}: #{inspect(value, pretty: true)}" end)
  end

  defp is_published?(content_admin) do
    now = DateTime.utc_now()
    publish_at = parse_datetime_from_metadata(get_in(content_admin.metadata, ["publish_at"]))
    expires_at = parse_datetime_from_metadata(get_in(content_admin.metadata, ["expires_at"]))

    content_admin.parse_status == :success &&
      (is_nil(publish_at) || DateTime.compare(publish_at, now) != :gt) &&
      (is_nil(expires_at) || DateTime.compare(expires_at, now) == :gt)
  end

  defp public_url(content_admin) do
    protected = get_in(content_admin.metadata, ["protected"]) || false

    content_type =
      get_in(content_admin.metadata, ["content_type"]) || get_in(content_admin.metadata, ["type"])

    slug = get_in(content_admin.metadata, ["slug"])

    prefix = if protected, do: "/private", else: ""
    "#{prefix}/#{content_type}/#{slug}"
  end

  defp parse_datetime_from_metadata(metadata_value) do
    case metadata_value do
      nil ->
        nil

      %DateTime{} = dt ->
        dt

      string when is_binary(string) ->
        case DateTime.from_iso8601(string) do
          {:ok, datetime, _} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
