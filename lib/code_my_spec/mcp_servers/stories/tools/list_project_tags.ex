defmodule CodeMySpec.McpServers.Stories.Tools.ListProjectTags do
  @moduledoc """
  Lists all tags used in the project.

  Shows all available tags that have been applied to stories or components.
  Use this to see what organizational categories exist.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Tags

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case tags(frame) do
      {:ok, tags} -> {:reply, StoriesMapper.project_tags_response(tags), frame}
      {:error, reason} -> {:reply, StoriesMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, tags} <- tags(frame) do
      {:ok, Enum.map(tags, &row/1)}
    end
  end

  defp tags(frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:ok, Tags.list_project_tags(scope)}
    end
  end

  defp row(tag), do: %{"id" => tag.id, "name" => tag.name}
end
