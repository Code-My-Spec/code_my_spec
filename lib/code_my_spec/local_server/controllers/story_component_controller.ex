defmodule CodeMySpec.LocalServer.Controllers.StoryComponentController do
  @moduledoc """
  Controller for linking stories to architecture components by module name.
  """

  import Plug.Conn

  alias CodeMySpec.Components
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.RemoteClient

  @doc """
  Links a story to a component by module name.

  ## Request Body

  - `story_id` - Story UUID (required)
  - `module_name` - Component module name, e.g. "MyApp.Accounts" (required)

  ## Response

  - 200: `{"story_id": "...", "component_id": "...", "module_name": "...", "story_title": "..."}`
  - 400: `{"error": "..."}`
  - 404: `{"error": "..."}`
  """
  def set(conn) do
    scope = conn.assigns[:current_scope]
    %{"story_id" => story_id, "module_name" => module_name} = conn.body_params

    with {:story, story} when not is_nil(story) <- {:story, Stories.get_story(scope, story_id)},
         {:component, component} when not is_nil(component) <-
           {:component, Components.get_component_by_module_name(scope, module_name)},
         client = RemoteClient.new(scope, conn.assigns[:remote_client_opts] || []),
         {:ok, %{status: 200, body: %{"data" => story_data}}} <-
           RemoteClient.set_story_component(client, story.id, component.id) do
      updated = RemoteClient.deserialize_story(story_data)

      json_response(conn, 200, %{
        story_id: updated.id,
        story_title: updated.title,
        component_id: component.id,
        module_name: module_name
      })
    else
      {:story, nil} ->
        json_response(conn, 404, %{error: "Story not found: #{story_id}"})

      {:component, nil} ->
        json_response(conn, 404, %{error: "Component not found: #{module_name}"})

      {:ok, %{status: status, body: body}} ->
        json_response(conn, 502, %{error: "Remote API error: #{status} #{inspect(body)}"})

      {:error, reason} ->
        json_response(conn, 400, %{error: "Failed to link: #{inspect(reason)}"})
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
