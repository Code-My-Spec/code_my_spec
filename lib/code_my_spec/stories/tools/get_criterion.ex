defmodule CodeMySpec.Stories.Tools.GetCriterion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "get_criterion"

  @impl true
  def description do
    """
    Reads one acceptance criterion by its number, retired or active.

    Retired criteria are not listed by `get_story`; this is how to read one.
    """
  end

  @impl true
  def params do
    %{criterion_number: {:required, {:meta, :integer, [description: "Criterion number"]}}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         story when not is_nil(story) <- Stories.get_story(scope, criterion.story_id) do
      StoriesMapper.criterion_response(criterion, story)
    else
      nil -> StoriesMapper.criterion_not_found_error()
    end
  end
end
