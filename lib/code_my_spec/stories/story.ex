defmodule CodeMySpec.Stories.Story do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.AcceptanceCriteria.Criterion

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t(),
          description: String.t(),
          story: String.t() | nil,
          notes: String.t() | nil,
          ready_for_dev: boolean(),
          specs_ready: boolean(),
          epic_id: Ecto.UUID.t() | nil,
          acceptance_criteria: [String.t()],
          criteria: [CodeMySpec.AcceptanceCriteria.Criterion.t()],
          tags: [CodeMySpec.Tags.Tag.t()] | Ecto.Association.NotLoaded.t(),
          priority: integer() | nil,
          locked_at: DateTime.t() | nil,
          lock_expires_at: DateTime.t() | nil,
          locked_by: integer() | nil,
          project_id: Ecto.UUID.t() | nil,
          component_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          first_version: PaperTrail.Version.t() | nil,
          current_version: PaperTrail.Version.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Field descriptions for API documentation."
  def field_docs do
    %{
      title: "Story title, e.g. 'User Login Feature'",
      description: "Legacy alias for `story`; kept in sync automatically",
      story: "User story in 'As a [role], I want [goal] so that [value]' format",
      notes: "Working notes for the agent — mechanism, dependencies, caveats",
      ready_for_dev:
        "Whether the story is released for development. Stories produce no " <>
          "requirements until this is true. New stories start false",
      specs_ready:
        "Whether the story's BDD specs have gone green. Set by the " <>
          "specs-passing gate on a fresh green spex run, cleared when the " <>
          "chain restarts. Spex failures only block the agent on stories " <>
          "where this is true. New stories start false",
      epic_id: "Epic this story belongs to (a story belongs to at most one)",
      acceptance_criteria: "List of acceptance criteria strings",
      priority: "Priority order (1 = highest). Lower numbers are higher priority",
      component_id: "Linked component ID"
    }
  end

  schema "stories" do
    field :title, :string
    # `description` is the legacy field. `story` is the user-story sentence
    # ("As an X, I want Y, so that Z") and `notes` is the agent's working
    # scratch space. The two are kept in sync on write until `description`
    # is retired — see `sync_story_and_description/1`.
    field :description, :string
    field :story, :string
    field :notes, :string
    # Pace control. A story produces no requirements until it is released,
    # and new stories start parked. The default lives here rather than in
    # the migration.
    field :ready_for_dev, :boolean, default: false
    # Latch behind `bdd_specs_passing`. Freshness gates the flip, never the
    # state: once a green run sets this, a later edit that stales the run
    # leaves it alone. That is the whole reason the node could come back
    # after bab2f792 removed it for clamping downstream work.
    field :specs_ready, :boolean, default: false

    # The id this story had on the harness it was migrated from. Story ids are
    # per-deployment sequences and the ranges overlap, so without this the same
    # number names different stories on either side and nothing errors.
    field :migrated_from_id, :integer

    # The durable name for this story, as opposed to `id`, which is a
    # per-deployment sequence that renumbers on migration. Spex directories and
    # QA folders are named from this, so a file on disk keeps pointing at the
    # story it was written for.
    #
    # Seeded from the numbers already in those directory names, so nothing on
    # disk had to move: the drift it fixes was a uniform 51 here —
    # `test/spex/811_user_sees_the_agents_task_queue…` named a real but
    # unrelated story 811, while the story that owns those spex is 862.
    #
    # Unique per project, not globally.
    field :number, :integer
    field :acceptance_criteria, {:array, :string}
    # No `status`. It was a cached projection of the requirement graph that
    # nothing ever advanced: `:completed` had no writer anywhere, so all 124
    # stories on this project read `in_progress` including the ones sitting at
    # 6/6 satisfied. A finished story and an untouched one held the same value,
    # which is worse than a null — `in_progress` is a positive claim that work
    # remains, made about work that is done.
    #
    # Adding the missing writer would only have created the need for a reverse
    # edge the first time a spec changed. The requirement graph answers this per
    # story and is recomputed rather than remembered; `specs_ready` below is the
    # one latch worth storing, and it is stored precisely because it must *not*
    # follow the computation back down.
    field :priority, :integer
    field :locked_at, :utc_datetime
    field :lock_expires_at, :utc_datetime
    field :locked_by, :id
    field :project_id, :binary_id
    field :account_id, :binary_id

    # Ordered, because "the story's first criterion" is a thing callers say and
    # an unordered preload does not answer it the same way twice. Postgres
    # returns heap order, and an UPDATE moves a row to the end of it — so
    # recording a criterion's `spec_path` silently reorders the list, and a
    # fixture that wrote a spec for criterion A was followed by a test that
    # deleted "the first criterion"'s spec and got criterion B. Nothing errored;
    # the file simply stayed and the requirement stayed satisfied.
    has_many :criteria, CodeMySpec.AcceptanceCriteria.Criterion,
      on_replace: :delete,
      preload_order: [asc: :id]

    many_to_many :tags, CodeMySpec.Tags.Tag,
      join_through: CodeMySpec.Tags.StoryTag,
      on_replace: :delete

    belongs_to :first_version, PaperTrail.Version
    belongs_to :current_version, PaperTrail.Version, on_replace: :update
    belongs_to :component, CodeMySpec.Components.Component, type: :binary_id
    belongs_to :epic, CodeMySpec.Epics.Epic, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(story, attrs) do
    story
    |> cast(attrs, [
      :title,
      :description,
      :story,
      :notes,
      :ready_for_dev,
      :specs_ready,
      :priority,
      :locked_at,
      :lock_expires_at,
      :locked_by,
      :project_id,
      :component_id,
      :epic_id,
      :migrated_from_id,
      :number
    ])
    |> sync_story_and_description()
    |> clear_specs_ready_on_readiness_change()
    |> validate_required([
      :title,
      :story
    ])
    |> validate_lengths()
    |> cast_assoc(:criteria,
      with: &Criterion.nested_changeset/2,
      sort_param: :criteria_sort,
      drop_param: :criteria_drop
    )
    |> unique_constraint([:title, :project_id])
  end

  # Transitional: `description` and `story` hold the same user-story
  # sentence while both columns exist. New callers write `story`, legacy
  # callers write `description`, and whichever arrives is copied to the
  # other so all 160-odd existing readers keep working. Delete this once
  # `description` is dropped.
  # Keyed on *changes*, not fields: updating only `description` on a story
  # that already has `story` set must move both, or a read returns the stale
  # sentence. When both change, the caller meant what it said.
  defp sync_story_and_description(changeset) do
    story_change = get_change(changeset, :story)
    description_change = get_change(changeset, :description)

    cond do
      present?(story_change) and is_nil(description_change) ->
        put_change(changeset, :description, story_change)

      present?(description_change) and is_nil(story_change) ->
        put_change(changeset, :story, description_change)

      true ->
        changeset
    end
  end

  # The story sentence is a sentence, and `notes` is where the rest goes.
  #
  # Agents were writing prose into `description` — story interviews, Three
  # Amigos, the architect, ad-hoc `create_story` callers — which makes list
  # views unreadable and `get_story` hard to scan. `notes` exists for exactly
  # that content and nothing was steering anyone towards it (823).
  #
  # Measured on this project when the caps went in: 141 stories, **0** over 120
  # characters of title (longest 97), **18** over 600 of story text (longest
  # 3,167). So the title cap costs nothing today and is there to stop the drift;
  # the story cap is the one with teeth.
  #
  # Grandfathered by construction rather than by a flag. `validate_length/3`
  # builds on `validate_change/3`, which fires only for fields actually being
  # changed — so an update that touches `ready_for_dev` on one of those 18
  # stories passes untouched, and the cap applies the next time somebody
  # rewrites the sentence. That is the migration path the report asked for,
  # with no backfill and no cutover.
  #
  # `story` and `description` both, because `sync_story_and_description/1`
  # copies one into the other: capping only one would let the same text in
  # through the other door.
  @title_max 120
  @story_max 600

  defp validate_lengths(changeset) do
    changeset
    |> validate_length(:title,
      max: @title_max,
      message: "is too long (max #{@title_max} characters) — a title is a name, not a summary"
    )
    |> validate_length(:story, max: @story_max, message: too_long_message())
    |> validate_length(:description, max: @story_max, message: too_long_message())
  end

  defp too_long_message do
    "is too long (max #{@story_max} characters). The story field holds the " <>
      "sentence — \"As a [role], I want [goal] so that [value]\" — and nothing " <>
      "else. Move the mechanism, dependencies and caveats to `notes`, which is " <>
      "free-form, uncapped, and kept out of list views."
  end

  # Chain restart: releasing, parking, or re-releasing a story sends it
  # back to the top, and a latch earned on the previous pass says nothing
  # about this one.
  #
  # Skipped when the same changeset sets `specs_ready` explicitly — that's
  # the manual override or the specs-passing gate talking, and it wins.
  defp clear_specs_ready_on_readiness_change(changeset) do
    cond do
      is_nil(get_change(changeset, :ready_for_dev)) -> changeset
      not is_nil(get_change(changeset, :specs_ready)) -> changeset
      true -> put_change(changeset, :specs_ready, false)
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  @doc false
  def lock_changeset(story, attrs) do
    story
    |> cast(attrs, [
      :locked_at,
      :lock_expires_at,
      :locked_by
    ])
  end
end
