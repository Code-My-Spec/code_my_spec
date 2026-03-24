defmodule CodeMySpecLocalWeb.StoriesController do
  @moduledoc """
  LLM API for stories — listing, detail, and mutations.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Components
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpecLocalWeb.StoriesMarkdown

  @page_size 10

  def index(conn, %{"project_name" => project_name} = params) do
    scope = conn.assigns.current_scope
    page = parse_page(params["page"])
    search = params["search"]

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
        base_path: "/api/projects/#{project_name}"
      )

    text(conn, markdown)
  end

  def show(conn, %{"story_id" => story_id, "project_name" => project_name}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, story_id) do
      nil ->
        conn |> put_status(404) |> text("Story not found: #{story_id}")

      story ->
        story = Repo.preload(story, [:component, :tags])
        text(conn, StoriesMarkdown.show(story, base_path: "/api/projects/#{project_name}"))
    end
  end

  def set_component(conn, %{"story_id" => story_id, "module_name" => module_name}) do
    scope = conn.assigns.current_scope

    with {:story, story} when not is_nil(story) <- {:story, Stories.get_story(scope, story_id)},
         {:component, component} when not is_nil(component) <-
           {:component, Components.get_component_by_module_name(scope, module_name)},
         {:ok, _updated} <- Stories.set_story_component(scope, story, component.id) do
      text(conn, "Linked story **#{story.title}** to component `#{module_name}`.\n")
    else
      {:story, nil} ->
        conn |> put_status(404) |> text("Story not found: #{story_id}")

      {:component, nil} ->
        conn |> put_status(404) |> text("Component not found: #{module_name}")

      {:error, reason} ->
        conn |> put_status(422) |> text("Failed to link: #{inspect(reason)}")
    end
  end

  def set_component(conn, _params) do
    conn |> put_status(400) |> text("Required: story_id (in URL) and module_name (in body)")
  end

  defp parse_page(nil), do: 1
  defp parse_page(val) when is_binary(val), do: max(String.to_integer(val), 1)
  defp parse_page(val) when is_integer(val), do: max(val, 1)
end
