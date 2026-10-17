defmodule CodeMySpec.McpServers.Stories.Tools.GetCriterion do
  @moduledoc """
  Reads one acceptance criterion by its number, retired or active.

  Retired criteria are not listed by `get_story`; this is how to read one.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  schema do
    field :criterion_number, :integer, required: true, description: "Criterion number"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         story when not is_nil(story) <- Stories.get_story(scope, criterion.story_id) do
      {:reply, StoriesMapper.criterion_response(criterion, story), frame}
    else
      nil -> {:reply, StoriesMapper.criterion_not_found_error(), frame}
    end
  end
end
