defmodule CodeMySpec.McpServers.Stories.Tools.AddCriterion do
  @moduledoc """
  Adds a new acceptance criterion to a story.

  Use get_story to see existing criteria before adding.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_id, :string, required: true, doc: "Story ID to add criterion to"
    field :description, :string, required: true, doc: "The acceptance criterion text"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, criterion} <-
           AcceptanceCriteria.create_criterion(scope, story, %{description: params.description}) do
      {:reply, StoriesMapper.criterion_added_response(criterion, story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
