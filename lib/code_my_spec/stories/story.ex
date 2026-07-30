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
          status: :active | :in_progress | :completed | :dirty,
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
      status: "Story status: in_progress, completed, or dirty",
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
    field :acceptance_criteria, {:array, :string}
    # `:active` is a legacy status that predates the narrowed enum
    # (`:in_progress | :completed | :dirty`). Accepted on read to
    # tolerate stale rows on remote servers; new writes use the
    # narrowed values.
    field :status, Ecto.Enum, values: [:active, :in_progress, :completed, :dirty]
    field :priority, :integer
    field :locked_at, :utc_datetime
    field :lock_expires_at, :utc_datetime
    field :locked_by, :id
    field :project_id, :binary_id
    field :account_id, :binary_id

    has_many :criteria, CodeMySpec.AcceptanceCriteria.Criterion, on_replace: :delete

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
      :status,
      :priority,
      :locked_at,
      :lock_expires_at,
      :locked_by,
      :project_id,
      :component_id,
      :epic_id
    ])
    |> sync_story_and_description()
    |> clear_specs_ready_on_readiness_change()
    |> validate_required([
      :title,
      :story
    ])
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
