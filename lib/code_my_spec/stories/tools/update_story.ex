defmodule CodeMySpec.Stories.Tools.UpdateStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories
  alias CodeMySpec.Tags

  @impl true
  def name, do: "update_story"

  @impl true
  def description do
    """
    Updates a user story.

    A story's criteria are not touched here. They change only through the
    criterion tools (`add_criterion`, `retire_criterion`), so each keeps
    its number for life.

    ## Tags

    Tags can be simple (`urgent`) or namespaced (`epic:auth`, `persona:admin`).
    Use `list_stories(tag: "...")` to filter by tag.
    """
  end

  @impl true
  def params do
    %{
      priority:
        {:meta, :integer,
         [
           description:
             "Priority order (1 = highest). Lower numbers are higher priority. (optional)"
         ]},
      description:
        {:meta, :string,
         [
           description:
             "New description in 'As a [role], I want [goal] so that [value]' format. Role must be a real human, not a system or technical component (optional)"
         ]},
      title: {:meta, :string, [description: "New title (optional)"]},
      tags: {:meta, {:list, :string}, [description: "Replace all tags with these (optional)"]},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}},
      story:
        {:meta, :string,
         [
           description:
             "User-story sentence in 'As a [role], I want [goal] so that [value]' format. Keep it to the sentence — mechanism and caveats belong in `notes` (optional)"
         ]},
      ready_for_dev:
        {:meta, :boolean,
         [
           description:
             "Release the story for development, or park it. Parked stories produce no requirements in the development graph (optional)"
         ]},
      epic_id:
        {:meta, :string,
         [
           description:
             "Move the story into this epic, or pass null to take it out. Prefer `assign_story_to_epic`, which takes the epic's name (optional)"
         ]},
      notes:
        {:meta, :string,
         [description: "Working notes — mechanism, dependencies, caveats (optional)"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, story} <- Stories.update_story(scope, story, Map.drop(params, [:story_number])),
         {:ok, story} <- sync_tags_if_provided(scope, story, params) do
      StoriesMapper.story_updated_response(story)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end

  defp sync_tags_if_provided(scope, story, params) do
    if Map.has_key?(params, :tags) do
      Tags.sync_tags(scope, story, params.tags)
      # Reload to get updated tags
      {:ok, Stories.get_story!(scope, story.id)}
    else
      {:ok, story}
    end
  end
end
