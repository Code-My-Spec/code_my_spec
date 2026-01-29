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

  def list_project_stories_by_component_priority(conn, _params) do
    scope = conn.assigns.current_scope
    stories = Stories.list_project_stories_by_component_priority(scope)
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
