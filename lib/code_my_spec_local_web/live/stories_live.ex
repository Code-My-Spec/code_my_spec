defmodule CodeMySpecLocalWeb.StoriesLive do
  @moduledoc """
  Human interface for browsing stories with pagination and detail view.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.StoriesMarkdown

  @page_size 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name, "story_id" => story_id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      case Stories.get_story(scope, story_id) do
        nil ->
          {:noreply, assign(socket, error: "Story not found: #{story_id}")}

        story ->
          story = Repo.preload(story, [:component, :tags])
          slug = project_slug(project)
          markdown = StoriesMarkdown.show(story, base_path: "/projects/#{slug}")
          {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  def handle_params(%{"project_name" => name} = params, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      page = parse_page(params["page"])
      search = params["search"]
      slug = project_slug(project)

      {stories, total} =
        Stories.list_project_stories_paginated(scope,
          limit: @page_size,
          offset: (page - 1) * @page_size,
          search: search
        )

      stories = Repo.preload(stories, [:component, :tags])
      total_pages = max(ceil(total / @page_size), 1)

      markdown =
        StoriesMarkdown.index(stories,
          page: page,
          total_pages: total_pages,
          total: total,
          search: search,
          base_path: "/projects/#{slug}"
        )

      {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="text-red-400">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  defp parse_page(nil), do: 1
  defp parse_page(val) when is_binary(val), do: max(String.to_integer(val), 1)
  defp parse_page(val) when is_integer(val), do: max(val, 1)

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
