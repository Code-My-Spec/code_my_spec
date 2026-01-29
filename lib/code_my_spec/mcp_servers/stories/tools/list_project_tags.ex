defmodule CodeMySpec.McpServers.Stories.Tools.ListProjectTags do
  @moduledoc """
  Lists all tags used in the project.

  Shows all available tags that have been applied to stories or components.
  Use this to see what organizational categories exist.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      tags = Tags.list_project_tags(scope)
      {:reply, StoriesMapper.project_tags_response(tags), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
