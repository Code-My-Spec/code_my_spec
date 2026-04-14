defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponent do
  @moduledoc """
  Links a story to the component that implements it, by module name.

  Delegates to the remote server API — story mutations happen server-side,
  then sync back down to the local clone.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Stories
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
    remote_opts = Map.get(frame.assigns, :remote_client_opts, [])

    with component when not is_nil(component) <-
           Components.get_component_by_module_name(scope, params.module_name),
         story when not is_nil(story) <-
           Stories.get_story(scope, params.story_id),
         {:ok, updated} <-
           Stories.set_story_component(scope, story, component.id) do
      # Sync stories from remote so local clone has the updated component_id
      CodeMySpec.Stories.RemoteSync.sync(scope, remote_opts)

      {:reply, StoriesMapper.story_component_set_response(updated), frame}
    else
      nil ->
        {:reply, StoriesMapper.error("Component or story not found: #{params.module_name}"), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
