defmodule CodeMySpec.Stories.Story do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Stories.AcceptanceCriteria.Criterion

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t(),
          description: String.t(),
          story: String.t() | nil,
          notes: String.t() | nil,
          ready_for_dev: boolean(),
          specs_ready: boolean(),
          specs_ready_at: DateTime.t() | nil,
          specs_ready_commit: String.t() | nil,
          qa_ready_commit: String.t() | nil,
          qa_ready_at: DateTime.t() | nil,
          qa_reviewed_commit: String.t() | nil,
          qa_reviewed_at: DateTime.t() | nil,
          three_amigos_sealed: boolean(),
          promoted_version: String.t() | nil,
          epic_id: Ecto.UUID.t() | nil,
          working_copy_id: Ecto.UUID.t() | nil,
          acceptance_criteria: [String.t()],
          criteria: [CodeMySpec.Stories.AcceptanceCriteria.Criterion.t()],
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
        "Whether the story is promoted with its BDD specs green. Set only by " <>
          "promotion, cleared when its spex, criteria or readiness change. " <>
          "Spex failures only block other copies' promotions on stories " <>
          "where this is true. New stories start false",
      specs_ready_at:
        "When specs_ready was last set true. Display only — a stop-hook " <>
          "refusal citing this story's spex names it so a different " <>
          "checkout can tell an old, earned-elsewhere latch from its own " <>
          "fresh regression. nil when specs_ready is false",
      specs_ready_commit:
        "The commit sha of the checkout that earned specs_ready, or nil. " <>
          "Same display-only purpose as specs_ready_at — never checked for " <>
          "ancestry, only shown",
      qa_ready_commit:
        "The commit the story's working copy was certified ready for QA at " <>
          "(clean tree, all four analyzers clean there, the story's own spex " <>
          "green), or nil. Set only by completing the ready_for_qa task; " <>
          "cleared with specs_ready",
      qa_ready_at: "When qa_ready_commit was stamped, or nil",
      qa_reviewed_commit:
        "The certification a QA pass must have reviewed for this story: qa_ready_commit, " <>
          "or an earlier certified commit when nothing QA exercises changed since",
      qa_reviewed_at: "When the certification qa_reviewed_commit names was stamped",
      three_amigos_sealed:
        "Whether the story's Three Amigos session has been sealed. Set by the " <>
          "gate when persona, rules, scenarios and zero open questions all " <>
          "hold. Sealing is refused while any red card is open. New stories " <>
          "start false",
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
    # Promoted, with the story's spex green on the certifying run: set only by
    # promotion. Decides whether this story's red spex block another copy's
    # promote (`Blocking.enforceable/2`).
    field :specs_ready, :boolean, default: false

    # When and where the latch above was earned. Display data only, so a reader
    # on a different checkout can tell "I broke this" from "earned elsewhere";
    # never checked for ancestry (that would shell git on every stop).
    field :specs_ready_at, :utc_datetime_usec
    field :specs_ready_commit, :string

    # The ready-for-QA stamp behind `ready_for_qa`: the commit
    # `Promotion.certify/3` passed at. Separate from `specs_ready`: it is per
    # copy and pre-merge, and must not make red spex block other promotes.
    field :qa_ready_commit, :string
    field :qa_ready_at, :utc_datetime_usec

    # The certification a QA pass must have reviewed: the stamp itself, or an
    # earlier one carried forward because nothing QA exercises changed, so a
    # test-only commit after QA does not cost another QA pass.
    field :qa_reviewed_commit, :string
    field :qa_reviewed_at, :utc_datetime_usec

    # Latch behind `three_amigos_complete`: a seal records a conversation that
    # happened, and a later question does not undo it.
    field :three_amigos_sealed, :boolean, default: false

    # The version a promotion stamped this story with, or nil. Set once, by
    # `CodeMySpec.Promotion` alone — never by an edit, never from live git
    # state — so it answers "did this story's code reach main", which later
    # work on the checkout cannot unmake. Clearing it sends the story back
    # through `story_promoted`.
    field :promoted_version, :string
    # Historical attribution survives release of the active working-copy assignment.
    field :promoted_working_copy_id, :binary_id
    field :promoted_at, :utc_datetime_usec

    # The id this story had on the harness it was migrated from. Story ids are
    # per-deployment sequences and the ranges overlap, so without this the same
    # number names different stories on either side and nothing errors.
    field :migrated_from_id, :integer

    # The durable name for this story, as opposed to `id`, which is a
    # per-deployment sequence that renumbers on migration. Spex directories and
    # QA folders are named from this. Unique per project, not globally.
    field :number, :integer

    # Stories are retired, never deleted, so a number is never freed. A retired
    # story leaves the backlog and the graph and stays readable by id and number.
    field :retired_at, :utc_datetime_usec
    field :acceptance_criteria, {:array, :string}
    # No `status`: the requirement graph answers a story's progress; a cached
    # copy of it goes stale. Only latches that must not follow the computation
    # back down are stored.
    field :priority, :integer
    field :locked_at, :utc_datetime_usec
    field :lock_expires_at, :utc_datetime_usec
    field :locked_by, :id
    field :project_id, :binary_id
    field :account_id, :binary_id

    # Ordered: Postgres returns heap order, and an UPDATE moves a row to the
    # end, so "the first criterion" would change under an unrelated write.
    #
    # Active criteria only. A retired one keeps its row and number, and is
    # read by number rather than through the story.
    has_many :criteria, CodeMySpec.Stories.AcceptanceCriteria.Criterion,
      on_replace: :delete,
      preload_order: [asc: :id],
      where: [retired_at: nil]

    many_to_many :tags, CodeMySpec.Tags.Tag,
      join_through: CodeMySpec.Tags.StoryTag,
      on_replace: :delete

    belongs_to :first_version, PaperTrail.Version
    belongs_to :current_version, PaperTrail.Version, on_replace: :update
    belongs_to :component, CodeMySpec.Components.Component, type: :binary_id
    belongs_to :epic, CodeMySpec.Epics.Epic, type: :binary_id

    # Which checkout this story is built on, or nil for the shared backlog.
    # On the story, not the epic, because the graph's grain is the story.
    # Nil means every working copy: a copy sees its own stories and every
    # unassigned one, never another copy's.
    belongs_to :working_copy, CodeMySpec.WorkingCopies.WorkingCopy, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts and validates a story's own fields — does not touch locking."
  def changeset(story, attrs) do
    story
    |> cast(attrs, [
      :title,
      :description,
      :story,
      :notes,
      :ready_for_dev,
      :specs_ready,
      :specs_ready_at,
      :specs_ready_commit,
      :qa_ready_commit,
      :qa_ready_at,
      :qa_reviewed_commit,
      :qa_reviewed_at,
      :three_amigos_sealed,
      :promoted_version,
      :promoted_working_copy_id,
      :promoted_at,
      :priority,
      :locked_at,
      :lock_expires_at,
      :locked_by,
      :project_id,
      :component_id,
      :epic_id,
      :working_copy_id,
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

  # A criterion dropped from the list is retired, not deleted, so its number
  # is never freed. `cast_assoc` marks it `:replace`, which `on_replace:
  # :delete` would carry out; turning it into an update that sets
  # `retired_at` keeps the row. Written into `changes` directly because
  # `put_change` would run the relation diff again and re-mark it.
  #
  # Not in `changeset/2`: `inputs_for` hides `:replace` entries, which is how
  # the live form drops a row, and an `:update` would keep it on screen. Called
  # by the repository only, right before persisting.
  @doc "Converts a dropped (`:replace`) criterion into a retire-in-place update. Call right before persisting, never from `changeset/2` itself — see comment above."
  def retire_dropped_criteria(changeset) do
    case get_change(changeset, :criteria) do
      nil ->
        changeset

      criteria ->
        %{
          changeset
          | changes:
              Map.put(changeset.changes, :criteria, Enum.map(criteria, &retire_if_replaced/1))
        }
    end
  end

  defp retire_if_replaced(%Ecto.Changeset{action: :replace} = criterion),
    do: %{Criterion.retire_changeset(criterion.data) | action: :update}

  defp retire_if_replaced(criterion), do: criterion

  # Transitional: `description` and `story` hold the same user-story
  # sentence while both columns exist. New callers write `story`, legacy
  # callers write `description`, and whichever arrives is copied to the
  # other so existing readers keep working. Delete this once `description` is
  # dropped.
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

  # The story sentence is a sentence; prose goes in `notes`. Caps apply only to
  # fields being changed, so older long stories pass until rewritten. Both
  # `story` and `description`, since one is copied into the other.
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
  # Skipped when the same changeset sets `specs_ready` explicitly; that wins.
  # Clears the QA stamps too.
  defp clear_specs_ready_on_readiness_change(changeset) do
    cond do
      is_nil(get_change(changeset, :ready_for_dev)) ->
        changeset

      not is_nil(get_change(changeset, :specs_ready)) ->
        changeset

      true ->
        changeset
        |> put_change(:specs_ready, false)
        |> put_change(:specs_ready_at, nil)
        |> put_change(:specs_ready_commit, nil)
        |> put_change(:qa_ready_commit, nil)
        |> put_change(:qa_ready_at, nil)
        |> put_change(:qa_reviewed_commit, nil)
        |> put_change(:qa_reviewed_at, nil)
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  @doc "Casts the lock fields (`locked_at`, `lock_expires_at`, `locked_by`) only."
  def lock_changeset(story, attrs) do
    story
    |> cast(attrs, [
      :locked_at,
      :lock_expires_at,
      :locked_by
    ])
  end
end
