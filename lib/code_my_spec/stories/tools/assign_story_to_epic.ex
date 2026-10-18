defmodule CodeMySpec.Stories.Tools.AssignStoryToEpic do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Epics
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "assign_story_to_epic"

  @impl true
  def description do
    """
    Moves a story into an epic.

    A story belongs to at most one epic, so this is a move rather than an add —
    the story leaves whatever epic it was in. Omit `epic_name` to remove the
    story from its epic entirely.

    Assignment does not change readiness.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}},
      epic_name:
        {:meta, :string,
         [description: "Destination epic name. Omit to remove the story from its epic."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- fetch_story(scope, params.story_number),
         {:ok, epic} <- fetch_epic(scope, params[:epic_name]),
         {:ok, _story} <- Epics.assign_story(scope, story, epic) do
      render(story, epic)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end

  defp fetch_story(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  defp fetch_epic(_scope, nil), do: {:ok, nil}
  defp fetch_epic(_scope, ""), do: {:ok, nil}

  defp fetch_epic(scope, name) do
    case Epics.get_epic_by_name(scope, name) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  defp render(story, nil) do
    {:ok, "Story \"#{story.title}\" (story #{story.number}) removed from its epic."}
  end

  defp render(story, epic) do
    {:ok, ~s[Story "#{story.title}" (story #{story.number}) moved into epic "#{epic.name}".]}
  end
end
