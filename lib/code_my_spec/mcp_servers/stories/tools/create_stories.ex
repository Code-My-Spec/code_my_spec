defmodule CodeMySpec.McpServers.Stories.Tools.CreateStories do
  @moduledoc """
  Creates multiple user stories in batch.
  Returns successful creations and any validation errors.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :stories, {:list, :map}, required: true
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        create_batch(scope, params, frame)

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end

  defp create_batch(scope, params, frame) do
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
  end
end
