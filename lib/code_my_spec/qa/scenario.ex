defmodule CodeMySpec.Qa.Scenario do
  @moduledoc """
  Embedded schema for a single QA scenario within a QaAttempt.

  Each scenario has a name, a pass/partial/fail status, and a free-text
  observation describing the finding or confirmation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pass, :partial, :fail]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          status: :pass | :partial | :fail | nil,
          observation: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :name, :string
    field :status, Ecto.Enum, values: @statuses
    field :observation, :string
  end

  @doc "Changeset for a Scenario."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scenario \\ %__MODULE__{}, attrs) do
    scenario
    |> cast(attrs, [:name, :status, :observation])
    |> validate_required([:name, :status, :observation])
  end
end
