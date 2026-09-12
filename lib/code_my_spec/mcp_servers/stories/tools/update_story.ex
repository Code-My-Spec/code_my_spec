defmodule CodeMySpec.McpServers.Stories.Tools.UpdateStory do
  @moduledoc """
  Updates a user story.

  Include all acceptance criteria in the input. Non-verified criteria will be
  replaced with your input. Verified (locked) criteria are preserved and cannot
  be modified or deleted via this tool - they are protected from LLM changes.

  ## Tags

  Tags can be simple (`urgent`) or namespaced (`epic:auth`, `persona:admin`).
  Use `list_stories(tag: "...")` to filter by tag.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias CodeMySpec.Tags

  schema do
    field :story_id, :string,
      required: true,
      doc: "Story ID to update (use list_story_titles to find IDs)"

    field :title, :string, doc: "New title (optional)"

    field :description, :string,
      doc:
        "New description in 'As a [role], I want [goal] so that [value]' format. " <>
          "Role must be a real human, not a system or technical component (optional)"

    field :story, :string,
      doc:
        "User-story sentence in 'As a [role], I want [goal] so that [value]' format. " <>
          "Keep it to the sentence — mechanism and caveats belong in `notes` (optional)"

    field :notes, :string, doc: "Working notes — mechanism, dependencies, caveats (optional)"

    field :ready_for_dev, :boolean,
      doc:
        "Release the story for development, or park it. Parked stories produce " <>
          "no requirements in the development graph (optional)"

    field :acceptance_criteria, {:list, :string},
      doc: "Replace unverified criteria with these (optional)"

    field :tags, {:list, :string}, doc: "Replace all tags with these (optional)"

    field :priority, :integer,
      doc: "Priority order (1 = highest). Lower numbers are higher priority. (optional)"

    # Declared because it was already reaching the changeset — `transform_params/2`
    # passes everything but `story_id` and `acceptance_criteria` straight
    # through, and `Story.changeset/2` casts `:epic_id`. What was missing was
    # this line, and Anubis drops an undeclared parameter in silence, so a
    # caller passing `epic_id` got a success and no change.
    #
    # `assign_story_to_epic` remains the usual route — it takes a name and reads
    # better at a call site. This is for a caller that already holds the id.
    field :epic_id, :string,
      doc:
        "Move the story into this epic, or pass null to take it out. " <>
          "Prefer `assign_story_to_epic`, which takes the epic's name (optional)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         update_params <- transform_params(params, story),
         {:ok, story} <- Stories.update_story(scope, story, update_params),
         {:ok, story} <- sync_tags_if_provided(scope, story, params) do
      {:reply, StoriesMapper.story_updated_response(story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
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

  # Transform params, respecting verified (locked) criteria
  defp transform_params(params, story) do
    base_params = Map.drop(params, [:story_id, :acceptance_criteria])

    # Only transform criteria if acceptance_criteria was provided
    if Map.has_key?(params, :acceptance_criteria) do
      criteria = build_criteria_params(params.acceptance_criteria, story.criteria)
      Map.put(base_params, :criteria, criteria)
    else
      base_params
    end
  end

  # Build criteria params that preserve verified criteria and replace unverified ones
  defp build_criteria_params(new_descriptions, existing_criteria) do
    # Keep verified criteria with their IDs (so they're preserved via cast_assoc)
    verified_criteria =
      existing_criteria
      |> Enum.filter(& &1.verified)
      |> Enum.map(fn c ->
        %{id: c.id, description: c.description, verified: c.verified, verified_at: c.verified_at}
      end)

    # Transform new descriptions to criteria params (these will replace unverified criteria)
    new_criteria =
      new_descriptions
      |> Enum.map(fn description -> %{description: description} end)

    # Verified criteria come first, then new criteria
    verified_criteria ++ new_criteria
  end
end
