defmodule CodeMySpecWeb.StoriesController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Stories

  action_fallback CodeMySpecWeb.FallbackController

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    stories = Stories.list_stories(scope)
    render(conn, :index, stories: stories)
  end

  def list_project_stories(conn, _params) do
    scope = conn.assigns.current_scope
    {:ok, stories} = Stories.list_project_stories(scope)
    render(conn, :index, stories: stories)
  end

  def list_project_stories_paginated(conn, params) do
    scope = conn.assigns.current_scope

    opts =
      [
        limit: params["limit"] && String.to_integer(params["limit"]),
        offset: params["offset"] && String.to_integer(params["offset"]),
        search: params["search"],
        tag: params["tag"]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {stories, total} = Stories.list_project_stories_paginated(scope, opts)
    render(conn, :paginated, stories: stories, total: total)
  end

  def list_story_titles(conn, params) do
    scope = conn.assigns.current_scope

    opts =
      if params["search"],
        do: [search: params["search"]],
        else: []

    titles = Stories.list_story_titles(scope, opts)
    render(conn, :titles, titles: titles)
  end

  def list_project_stories_by_priority(conn, _params) do
    scope = conn.assigns.current_scope
    stories = Stories.list_project_stories_by_priority(scope)
    render(conn, :index, stories: stories)
  end

  def list_unsatisfied_stories(conn, _params) do
    scope = conn.assigns.current_scope
    stories = Stories.list_unsatisfied_stories(scope)
    render(conn, :index, stories: stories)
  end

  def list_component_stories(conn, %{"component_id" => component_id}) do
    scope = conn.assigns.current_scope
    stories = Stories.list_component_stories(scope, component_id)
    render(conn, :index, stories: stories)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found"})

      story ->
        render(conn, :show, story: story)
    end
  end

  def create(conn, %{"story" => story_params}) do
    scope = conn.assigns.current_scope

    with {:ok, story} <- Stories.create_story(scope, story_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/stories/#{story}")
      |> render(:show, story: story)
    end
  end

  def update(conn, %{"id" => id, "story" => story_params}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found"})

      story ->
        with {:ok, story} <- Stories.update_story(scope, story, story_params) do
          render(conn, :show, story: story)
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found"})

      story ->
        with {:ok, story} <- Stories.delete_story(scope, story) do
          render(conn, :show, story: story)
        end
    end
  end

  def set_component(conn, %{"stories_id" => id, "component_id" => component_id}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found"})

      story ->
        with {:ok, story} <- Stories.set_story_component(scope, story, component_id) do
          render(conn, :show, story: story)
        end
    end
  end

  def bulk_set_component(conn, %{"links" => links}) when is_list(links) do
    scope = conn.assigns.current_scope
    parsed = Enum.map(links, &parse_bulk_link/1)

    case Stories.bulk_set_story_component(scope, parsed) do
      {:ok, stories} ->
        render(conn, :index, stories: stories)

      {:error, {:not_found, story_id}} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found", story_id: story_id})

      {:error, {:unauthorized, story_id}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{status: "forbidden", error: "Unauthorized", story_id: story_id})

      {:error, {:invalid, story_id, %Ecto.Changeset{} = changeset}} ->
        errors = Ecto.Changeset.traverse_errors(changeset, &translate_changeset_error/1)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "unprocessable_entity", story_id: story_id, errors: errors})
    end
  end

  defp translate_changeset_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp parse_bulk_link(%{"story_id" => story_id, "component_id" => component_id}) do
    %{story_id: story_id, component_id: component_id}
  end

  def clear_component(conn, %{"stories_id" => id}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Story not found"})

      story ->
        with {:ok, story} <- Stories.clear_story_component(scope, story) do
          render(conn, :show, story: story)
        end
    end
  end
end
