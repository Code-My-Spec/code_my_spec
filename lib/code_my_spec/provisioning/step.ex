defmodule CodeMySpec.Provisioning.Step do
  @moduledoc """
  One named step in the setup sequence and its state.

  ## The five states

  `:not_started`, `:running`, `:done`, `:errored`, and `:paused`. The last
  two are genuinely different and story 963 turns on the difference:

  - `:errored` means the provider refused and setup cannot proceed on its
    own. Criterion 7961 requires the run to halt here rather than press on —
    a deploy against a domain that never got registered builds on nothing.
  - `:paused` means setup is waiting on something Sam must do somewhere else
    (register a TLD the API cannot sell, click a console confirmation).
    Criterion 7967 requires that his mere *return* is not taken as proof the
    errand was done — the step re-checks and stays paused if it still is not
    true.

  ## Why the provider's own words are stored

  `attempted` and `provider_error` exist so a failure can be handed to the
  setup agent with enough context to act on. Criterion 7962 asserts the
  escalation names the step, says what it tried, and carries Cloudflare's own
  permission text — not a generic "domain step failed". A summarised error
  loses exactly the detail that tells the agent which token permission to
  add, so `provider_error` holds the provider's message verbatim.

  ## State is checked, not remembered

  Criterion 7970 requires a step's state to be validated against the provider
  rather than read back from this row, and criterion 7964 requires a resource
  deleted behind setup's back to be rebuilt rather than skipped. So this
  schema is a record of the last observation, not the source of truth about
  the world. Persisted `:done` is a claim to re-verify, never a reason to
  skip work.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.Resource

  @states [:not_started, :running, :done, :errored, :paused]

  # The sequence is fixed and named, because Sam is shown the whole plan
  # before anything runs (criterion 7959) and an option he turned off must
  # never appear in it (criterion 7968). Free-text keys would make both
  # unstateable.
  @keys [
    # First in the sequence, and that ordering is load-bearing: CI publishes
    # the image the deploy pulls, so a deploy with no remote has nothing to
    # build from. Story 985 criterion 8182.
    :repository,
    :server,
    :secrets,
    :domain,
    :dns,
    :tls,
    :deploy,
    :email,
    :inbound,
    :storage,
    :backups,
    :content,
    :widget,
    :callback_credential,
    :monitoring
  ]

  @type state :: :not_started | :running | :done | :errored | :paused

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t(),
          key: atom(),
          state: state(),
          position: integer(),
          attempted: String.t() | nil,
          provider_error: String.t() | nil,
          paused_instructions: String.t() | nil,
          resources: [Resource.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "provisioning_steps" do
    field :key, Ecto.Enum, values: @keys
    field :state, Ecto.Enum, values: @states, default: :not_started
    field :position, :integer

    field :attempted, :string
    field :provider_error, :string
    field :paused_instructions, :string

    # When the step began, as distinct from `updated_at` (when it last
    # changed). Ordering claims need both ends.
    field :started_at, :utc_datetime_usec

    # When this was last checked against the provider — not when it last ran.
    field :verified_at, :utc_datetime_usec

    embeds_many :resources, Resource, on_replace: :delete

    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Every step key, in the order the sequence runs them."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "Every state a step can be in."
  @spec states() :: [state()]
  def states, do: @states

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :key,
      :state,
      :position,
      :attempted,
      :provider_error,
      :paused_instructions,
      :project_id,
      :started_at,
      :verified_at
    ])
    |> cast_embed(:resources)
    |> drop_the_other_state_s_diagnosis()
    |> validate_required([:key, :state, :position, :project_id])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_pause_is_actionable()
    |> validate_error_is_diagnosable()
    |> unique_constraint([:project_id, :key])
    |> foreign_key_constraint(:project_id)
  end

  # A step carries the diagnosis of the state it is in, and only that one.
  #
  # These fields are written when a step fails or pauses and were never cleared
  # when it moved on, so they accumulated: the inbound step failed against a
  # bad credential, was fixed, and then paused correctly — "the message sent
  # never arrived" — while still carrying the `400 "API key is invalid"` from
  # hours earlier. Everything reading the row showed the old provider failure,
  # because a provider error is the more specific-looking of the two. Four
  # drills went into chasing a field that nothing in those runs had written.
  #
  # Explicit values survive: only a field this changeset did not set and the
  # state does not own is dropped, so a caller that means to record both still
  # can.
  defp drop_the_other_state_s_diagnosis(changeset) do
    state = get_field(changeset, :state)

    changeset
    |> drop_unless(:provider_error, state == :errored)
    |> drop_unless(:paused_instructions, state == :paused)
  end

  defp drop_unless(changeset, field, owned_by_this_state?) do
    cond do
      owned_by_this_state? -> changeset
      not is_nil(get_change(changeset, field)) -> changeset
      is_nil(get_field(changeset, field)) -> changeset
      true -> put_change(changeset, field, nil)
    end
  end

  # A paused step that doesn't say what Sam must do elsewhere is a dead end:
  # the page renders `data-test='paused-instructions'` from this, and without
  # it he is told to go do something without being told what.
  defp validate_pause_is_actionable(changeset) do
    case get_field(changeset, :state) do
      :paused -> validate_required(changeset, [:paused_instructions])
      _ -> changeset
    end
  end

  # Same argument for the escalation path: an errored step with no provider
  # text hands the setup agent a failure it cannot diagnose, which is the
  # generic-message failure criterion 7962 exists to prevent.
  defp validate_error_is_diagnosable(changeset) do
    case get_field(changeset, :state) do
      :errored -> validate_required(changeset, [:attempted, :provider_error])
      _ -> changeset
    end
  end
end
