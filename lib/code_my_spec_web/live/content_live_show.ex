defmodule CodeMySpecWeb.ContentLive.Show do
  @moduledoc """
  Detail view for a single content snapshot row (story 712) — renders the full
  processed content (HTML) plus metadata and any parse errors. The full content
  lives here, not in the index table.
  """
  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.ContentLive.Helpers

  alias CodeMySpec.ContentPublishing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :content,
       page_title: "Content",
       row: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{scope: %{} = scope}} = socket) do
    # row may be nil (unknown / non-integer id) — the view renders a
    # not-found state rather than crashing.
    {:noreply, assign(socket, current_scope: scope, row: ContentPublishing.get_snapshot(scope, id))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
      <div :if={!@row && @slug} class="p-6" data-test="content-not-found">
        <.link navigate={path(@socket, ~p"/app/projects/#{@slug}/content")} class="link link-primary text-sm">
          ← Back to Content
        </.link>
        <p class="mt-4 text-base-content/60">Content not found.</p>
      </div>

      <div :if={@row}>
        <.link navigate={path(@socket, ~p"/app/projects/#{@slug}/content")} class="link link-primary text-sm">
          ← Back to Content
        </.link>

        <div class="flex items-center gap-3 mt-4 mb-4">
          <h1 class="text-3xl font-bold">{title(@row)}</h1>
          <span class="badge badge-ghost">{content_type(@row)}</span>
          <span class={["badge", status_class(@row.parse_status)]}>{to_string(@row.parse_status)}</span>
        </div>

        <div class="grid grid-cols-2 gap-3 mb-6 p-4 bg-base-200 rounded-box text-sm">
          <div><span class="font-semibold">Slug:</span> <span class="ml-2 font-mono">{slug(@row)}</span></div>
          <div><span class="font-semibold">Type:</span> <span class="ml-2">{content_type(@row)}</span></div>
          <div>
            <span class="font-semibold">Published:</span>
            <span class="ml-2 font-mono">{@row.metadata["publish_at"] || "—"}</span>
          </div>
          <div>
            <span class="font-semibold">Expires:</span>
            <span class="ml-2 font-mono">{@row.metadata["expires_at"] || "never"}</span>
          </div>
        </div>

        <div
          :if={@row.parse_status == :error}
          role="alert"
          class="alert alert-error alert-soft mb-6"
          data-test={"content-parse-error-#{filename(@row)}"}
        >
          <pre class="text-xs whitespace-pre-wrap">{format_errors(@row.parse_errors)}</pre>
        </div>

        <div
          :if={@row.processed_content}
          class="prose prose-sm max-w-none border border-base-300 rounded-box p-6 bg-base-100"
          data-test={"processed-content-#{slug(@row)}"}
        >
          {raw(@row.processed_content)}
        </div>
      </div>
    """
  end
end
