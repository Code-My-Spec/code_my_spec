defmodule CodeMySpec.McpServers.Stories.Tools.TagStories do
  @moduledoc """
  Adds a tag to multiple stories at once.

  Useful for bulk categorization when organizing stories by domain.

  ## Tag naming

  Tags can be simple (`notifications`, `urgent`) or use colon syntax for
  typed/namespaced tags (`epic:verification-flow`, `persona:driver`).

  The colon syntax is useful for organizing stories into categories that
  can be filtered, e.g., `list_stories(tag: "persona:driver")`.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias CodeMySpec.Tags

  schema do
    field :story_ids, {:list, :string}, required: true, doc: "List of story IDs to tag"
    field :tag, :string, required: true, doc: "Tag name to apply to all stories"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        results = Enum.map(params.story_ids, &tag_one(scope, &1, params.tag))

        successes = Enum.filter(results, &match?({:ok, _}, &1)) |> Enum.map(&elem(&1, 1))
        failures = Enum.filter(results, &match?({:error, _, _}, &1))

        {:reply, StoriesMapper.bulk_tag_response(successes, failures, params.tag), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end

  defp tag_one(scope, story_id, tag) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, story_id, :not_found}
      story -> apply_tag(scope, story, story_id, tag)
    end
  end

  defp apply_tag(scope, story, story_id, tag) do
    case Tags.add_tag(scope, story, tag) do
      {:ok, _tagging} -> {:ok, story_id}
      # Already tagged is OK
      {:error, _changeset} -> {:ok, story_id}
    end
  end
end
