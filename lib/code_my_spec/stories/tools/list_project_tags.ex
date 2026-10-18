defmodule CodeMySpec.Stories.Tools.ListProjectTags do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Tags

  @impl true
  def name, do: "list_project_tags"

  @impl true
  def description do
    """
    Lists all tags used in the project.

    Shows all available tags that have been applied to stories or components.
    Use this to see what organizational categories exist.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case tags(context) do
      {:ok, tags} -> StoriesMapper.project_tags_response(tags)
      {:error, reason} -> StoriesMapper.error(reason)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, tags} <- tags(context) do
      {:ok, Enum.map(tags, &row/1)}
    end
  end

  defp tags(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, Tags.list_project_tags(scope)}
    end
  end

  defp row(tag), do: %{"id" => tag.id, "name" => tag.name}
end
