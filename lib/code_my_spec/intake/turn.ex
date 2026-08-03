defmodule CodeMySpec.Intake.Turn do
  @moduledoc "One question the interview asked, and what the visitor said back."

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Intake.Plan

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          plan_id: Ecto.UUID.t() | nil,
          position: pos_integer(),
          question: String.t(),
          answer: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "intake_interview_turns" do
    field :position, :integer
    field :question, :string
    field :answer, :string

    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  def ask_changeset(%Plan{} = plan, position, question) do
    change(%__MODULE__{}, plan_id: plan.id, position: position, question: question)
    |> unique_constraint([:plan_id, :position])
  end

  def answer_changeset(%__MODULE__{} = turn, answer) do
    turn
    |> cast(%{answer: answer}, [:answer])
    |> validate_required([:answer])
    |> validate_length(:answer, min: 1, max: 2000)
  end
end
