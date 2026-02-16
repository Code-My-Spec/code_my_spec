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

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_ids, {:list, :string}, required: true, doc: "List of story IDs to tag"
    field :tag, :string, required: true, doc: "Tag name to apply to all stories"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      results =
        params.story_ids
        |> Enum.map(fn story_id ->
          case Stories.get_story(scope, story_id) do
            nil ->
              {:error, story_id, :not_found}

            story ->
              case Tags.add_tag(scope, story, params.tag) do
                {:ok, _tagging} -> {:ok, story_id}
                # Already tagged is OK
                {:error, _changeset} -> {:ok, story_id}
              end
          end
        end)

      successes = Enum.filter(results, &match?({:ok, _}, &1)) |> Enum.map(&elem(&1, 1))
      failures = Enum.filter(results, &match?({:error, _, _}, &1))

      {:reply, StoriesMapper.bulk_tag_response(successes, failures, params.tag), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
