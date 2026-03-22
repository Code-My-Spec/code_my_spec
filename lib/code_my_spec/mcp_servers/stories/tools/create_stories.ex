defmodule CodeMySpec.McpServers.Stories.Tools.CreateStories do
  @moduledoc """
  Creates multiple user stories in batch.
  Returns successful creations and any validation errors.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :stories, {:list, :map}, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      {successes, failures} =
        params.stories
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {story, index}, {success_acc, failure_acc} ->
          case Stories.create_story(scope, story) do
            {:ok, created_story} ->
              {[created_story | success_acc], failure_acc}

            {:error, changeset} ->
              {success_acc, [{index, changeset} | failure_acc]}
          end
        end)

      successes = Enum.reverse(successes)
      failures = Enum.reverse(failures)

      case failures do
        [] ->
          {:reply, StoriesMapper.stories_batch_response(successes), frame}

        _has_failures ->
          {:reply, StoriesMapper.batch_errors_response(successes, failures), frame}
      end
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
