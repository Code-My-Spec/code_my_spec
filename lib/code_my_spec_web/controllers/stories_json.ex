defmodule CodeMySpecWeb.StoriesJSON do
  alias CodeMySpec.Stories.Story

  @doc """
  Renders a list of stories.
  """
  def index(%{stories: stories}) do
    %{data: for(story <- stories, do: data(story))}
  end

  @doc """
  Renders a single story.
  """
  def show(%{story: story}) do
    %{data: data(story)}
  end

  defp data(%Story{} = story) do
    %{
      id: story.id,
      title: story.title,
      description: story.description,
      acceptance_criteria: story.acceptance_criteria,
      status: story.status,
      locked_at: story.locked_at,
      lock_expires_at: story.lock_expires_at,
      locked_by: story.locked_by,
      project_id: story.project_id,
      component_id: story.component_id,
      component: render_component(story.component),
      tags: render_tags(story.tags),
      account_id: story.account_id,
      inserted_at: story.inserted_at,
      updated_at: story.updated_at
    }
  end

  defp render_component(%Ecto.Association.NotLoaded{}), do: nil
  defp render_component(nil), do: nil

  defp render_component(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name
    }
  end

  defp render_tags(%Ecto.Association.NotLoaded{}), do: []
  defp render_tags(nil), do: []

  defp render_tags(tags) when is_list(tags) do
    Enum.map(tags, fn tag ->
      %{id: tag.id, name: tag.name}
    end)
  end
end
