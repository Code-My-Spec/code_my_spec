defmodule CodeMySpecWeb.StoryLive.Import do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Markdown

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error || @scope_error} role="alert" class="alert alert-error">
      <span>{@error || @scope_error}</span>
    </div>

    <div :if={!@error && @project}>
      <.header>
        Import Stories from Markdown
        <:subtitle>
          Upload a markdown file or paste content to import multiple stories at once.
        </:subtitle>
      </.header>

      <form phx-submit="import" phx-change="validate">
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text">Upload Markdown File</span>
          </label>
          <div
            class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center transition-colors"
            phx-drop-target={@uploads.markdown_file.ref}
          >
            <.live_file_input
              upload={@uploads.markdown_file}
              class="file-input file-input-bordered w-full"
            />
            <div class="mt-2">
              <span class="text-sm text-base-content/60">
                Drop your .md file here or click to browse
              </span>
            </div>
          </div>

          <%= for entry <- @uploads.markdown_file.entries do %>
            <div class="flex items-center gap-2 mt-2">
              <span class="text-sm">{entry.client_name}</span>
              <progress class="progress progress-primary w-20" value={entry.progress} max="100">
                {entry.progress}%
              </progress>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-xs btn-circle btn-outline"
              >
                ✕
              </button>
            </div>

            <%= for err <- upload_errors(@uploads.markdown_file, entry) do %>
              <div class="alert alert-error mt-2">
                <span>{error_to_string(err)}</span>
              </div>
            <% end %>
          <% end %>

          <%= for err <- upload_errors(@uploads.markdown_file) do %>
            <div class="alert alert-error mt-2">
              <span>{error_to_string(err)}</span>
            </div>
          <% end %>
        </div>

        <div class="divider">OR</div>

        <.input
          type="textarea"
          name="markdown_content"
          label="Paste Markdown Content"
          value={@markdown_content}
          rows="15"
          class="font-mono text-sm"
          placeholder={markdown_placeholder_content()}
        />

        <footer class="mt-6">
          <.button type="submit" phx-disable-with="Importing...">
            Import Stories
          </.button>
          <.button
            navigate={path(@socket, ~p"/app/projects/#{@slug}/stories")}
            class="btn btn-secondary"
          >
            Cancel
          </.button>
        </footer>
      </form>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       section: :stories,
       project: nil,
       scope: nil,
       slug: nil,
       error: nil,
       page_title: "Import Stories",
       markdown_content: ""
     )
     |> allow_upload(:markdown_file,
       accept: ~w(.md .markdown .txt),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  @impl true
  def handle_event("validate", %{"markdown_content" => content}, socket) do
    {:noreply, assign(socket, :markdown_content, content)}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :markdown_file, ref)}
  end

  @impl true
  def handle_event("import", params, socket) do
    markdown_content = get_markdown_content(socket, params)

    case Markdown.parse_markdown(markdown_content) do
      {:ok, story_attrs_list} ->
        import_stories(socket, story_attrs_list)

      {:error, reason} ->
        error_msg = format_error(reason)
        {:noreply, put_flash(socket, :error, "Import failed: #{error_msg}")}
    end
  end

  defp get_markdown_content(_socket, %{"markdown_content" => content}) when content != "" do
    content
  end

  defp get_markdown_content(socket, _params) do
    case socket.assigns.uploads.markdown_file.entries do
      [_entry] ->
        consume_uploaded_entries(socket, :markdown_file, fn %{path: path}, _entry ->
          File.read!(path)
        end)
        |> List.first() || ""

      [] ->
        ""
    end
  end

  defp import_stories(socket, story_attrs_list) do
    scope = socket.assigns.scope

    results =
      Enum.map(story_attrs_list, fn attrs ->
        Stories.create_story(scope, attrs)
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      count = length(story_attrs_list)

      {:noreply,
       socket
       |> put_flash(:info, "Successfully imported #{count} stories")
       |> push_navigate(to: path(socket, ~p"/app/projects/#{socket.assigns.slug}/stories"))}
    else
      {:noreply, put_flash(socket, :error, "Failed to import some stories")}
    end
  end

  defp format_error(:empty_document), do: "Document is empty"
  defp format_error(:invalid_format), do: "Invalid markdown format"
  defp format_error(:missing_story_data), do: "Missing Story Data"
  defp format_error(:missing_sections), do: "Markdown is missing required sections"

  defp error_to_string(:too_large), do: "File too large (max 1MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type (must be .md, .markdown, or .txt)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp markdown_placeholder_content do
    "## Story Title\n\nStory description here.\n\n**Acceptance Criteria**\n- Criterion 1\n- Criterion 2\n\n## Another Story\n\nAnother story description."
  end
end
