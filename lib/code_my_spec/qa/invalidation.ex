defmodule CodeMySpec.Qa.Invalidation do
  @moduledoc """
  Schema for a QA attempt invalidation event.

  Audit-stamped with the engineer's user ID, a timestamp, and a reason.
  The original QaAttempt is preserved; this row marks it as invalidated.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Users.User

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          qa_attempt_id: Ecto.UUID.t() | nil,
          invalidated_by_user_id: integer() | nil,
          reason: String.t() | nil,
          invalidated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "qa_invalidations" do
    field :reason, :string
    field :invalidated_at, :utc_datetime_usec

    belongs_to :qa_attempt, QaAttempt, type: :binary_id
    belongs_to :invalidated_by_user, User, foreign_key: :invalidated_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an Invalidation."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invalidation \\ %__MODULE__{}, attrs) do
    invalidation
    |> cast(attrs, [:qa_attempt_id, :invalidated_by_user_id, :reason, :invalidated_at])
    |> validate_required([:qa_attempt_id, :reason, :invalidated_at])
    |> validate_reason_non_empty()
    |> foreign_key_constraint(:invalidated_by_user_id)
  end

  defp validate_reason_non_empty(changeset) do
    reason = get_field(changeset, :reason)

    if reason && String.trim(reason) == "" do
      add_error(changeset, :reason, "must not be blank")
    else
      changeset
    end
  end
end
