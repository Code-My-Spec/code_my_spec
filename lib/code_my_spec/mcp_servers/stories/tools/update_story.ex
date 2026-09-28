defmodule CodeMySpec.McpServers.Stories.Tools.UpdateStory do
  @moduledoc """
  Updates a user story.

  `acceptance_criteria` is optional; leave it out to keep the criteria as they
  are. When sent, each description matching an existing criterion keeps that
  criterion and its number, a new description adds one, and an existing one
  left out is retired. Verified (locked) criteria are always kept. Prefer the
  criterion tools (`add_criterion`, `update_criterion`, `retire_criterion`).

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

  # Criteria are matched to the story's existing ones by wording, so an agent
  # that sends back the list it read keeps every criterion and its number.
  # Verified criteria are always kept. An unmatched description is a new
  # criterion; an existing one not sent is retired by the story changeset.
  defp build_criteria_params(new_descriptions, existing_criteria) do
    {verified, unverified} = Enum.split_with(existing_criteria, & &1.verified)

    kept_verified =
      Enum.map(verified, fn c ->
        %{id: c.id, description: c.description, verified: c.verified, verified_at: c.verified_at}
      end)

    {matched, _unused} =
      Enum.map_reduce(new_descriptions, unverified, fn description, pool ->
        case Enum.split_with(pool, &(&1.description == description)) do
          {[hit | rest], others} -> {%{id: hit.id, description: description}, rest ++ others}
          {[], _} -> {%{description: description}, pool}
        end
      end)

    kept_verified ++ matched
  end
end
