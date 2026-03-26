defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponent do
  @moduledoc """
  Links a story to the component that implements it, by module name.

  Delegates to the remote server API — story mutations happen server-side,
  then sync back down to the local clone.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Stories.RemoteClient
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID (use list_story_titles to find)"
    field :module_name, :string, required: true, doc: "Component module name, e.g. \"MyApp.Accounts\""
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        do_set_component(params, scope, frame)

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end

  defp do_set_component(params, scope, frame) do
    with component when not is_nil(component) <-
           Components.get_component_by_module_name(scope, params.module_name),
         client <- RemoteClient.new(scope),
         {:ok, %{status: 200, body: %{"data" => story_data}}} <-
           RemoteClient.set_story_component(client, params.story_id, component.id) do
      updated = RemoteClient.deserialize_story(story_data)

      # Sync stories from remote so local clone has the updated component_id
      CodeMySpec.Stories.RemoteSync.sync(scope)

      {:reply, StoriesMapper.story_component_set_response(updated), frame}
    else
      nil ->
        {:reply, StoriesMapper.error("Component not found: #{params.module_name}"), frame}

      {:ok, %{status: status, body: body}} ->
        {:reply, StoriesMapper.error("Remote API error: #{status} #{inspect(body)}"), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
