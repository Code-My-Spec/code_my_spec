defmodule CodeMySpec.Agents.Offer do
  @moduledoc """
  One nudge the harness sent an agent, and what became of it (b75b0198).

  `subject_type`/`subject_key` name what was offered: a requirement node, a
  task, a question, a blocker, a problem set. `status` is `:open` until the
  turn-end observer settles it from the kind's expectation, or `:undelivered`
  when its delivery failed or was held — never `:ignored`, which means the
  agent saw it (criterion 1676).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Agents.OfferMessage

  @kinds [:work, :menu, :problems, :resume, :retry, :answer, :unblocked, :check_in]
  @statuses [:open, :claimed, :declined, :ignored, :superseded, :expired, :n_a, :undelivered]

  @type kind :: :work | :menu | :problems | :resume | :retry | :answer | :unblocked | :check_in
  @type status ::
          :open
          | :claimed
          | :declined
          | :ignored
          | :superseded
          | :expired
          | :n_a
          | :undelivered
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "offers" do
    field :account_id, Ecto.UUID
    field :project_id, Ecto.UUID
    field :agent_id, Ecto.UUID
    field :working_copy_id, Ecto.UUID
    field :kind, Ecto.Enum, values: @kinds
    field :subject_type, :string
    field :subject_key, :string
    field :attempt, :integer
    field :status, Ecto.Enum, values: @statuses
    field :outcome_at, :utc_datetime_usec
    # An explicit decline's reason; reject_offer (step 2) writes it too.
    field :reason, :string
    # What the agent did, for kinds with no fixed expectation.
    field :note, :string
    # The policy step taken after this outcome (step 2).
    field :next_step, :string
    field :template_version, :string

    has_many :messages, OfferMessage

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @required [:agent_id, :kind, :subject_type, :attempt, :status, :template_version]
  @optional [
    :account_id,
    :project_id,
    :working_copy_id,
    :subject_key,
    :outcome_at,
    :reason,
    :note,
    :next_step
  ]

  def changeset(offer \\ %__MODULE__{}, attrs) do
    offer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:project_id)
  end
end
