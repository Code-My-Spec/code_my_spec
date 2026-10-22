defmodule CodeMySpec.Projects.OnboardingState do
  @moduledoc "Persisted setup decisions; execution readiness is derived from its own records."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:starting_point, Ecto.Enum, values: [:new, :existing])
    field(:description, :string)
    field(:setup_agent_id, Ecto.UUID)
    field(:setup_started_at, :utc_datetime_usec)
    field(:destination, Ecto.Enum, values: [:local, :cloud, :external])
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:starting_point, :description, :destination])
    |> validate_length(:description, max: 10_000)
  end
end
