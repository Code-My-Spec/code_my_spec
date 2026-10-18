defmodule CodeMySpec.Stories.Tools.AddCriterion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "add_criterion"

  @impl true
  def description do
    """
    Adds a new acceptance criterion to a story.

    Use get_story to see existing criteria before adding.
    """
  end

  @impl true
  def params do
    %{
      description: {:required, {:meta, :string, [description: "The acceptance criterion text"]}},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, criterion} <-
           AcceptanceCriteria.create_criterion(scope, story, %{description: params.description}) do
      StoriesMapper.criterion_added_response(criterion, story)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
