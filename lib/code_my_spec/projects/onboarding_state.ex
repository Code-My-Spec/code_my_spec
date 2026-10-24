defmodule CodeMySpec.Projects.OnboardingState do
  @moduledoc "Persisted setup decisions; execution readiness is derived from its own records."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:starting_point, Ecto.Enum, values: [:new, :existing])
    field(:description, :string)
    field(:destination_path, :string)
    field(:setup_agent_id, Ecto.UUID)
    field(:setup_started_at, :utc_datetime_usec)
    field(:destination, Ecto.Enum, values: [:local, :cloud, :external])
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:starting_point, :description, :destination, :destination_path])
    |> validate_length(:description, max: 10_000)
    |> validate_length(:destination_path, max: 4096)
    |> validate_format(:destination_path, ~r{\A(?:/|[A-Za-z]:[\\/]|\\\\)},
      message: "must be an absolute path on the development device"
    )
  end
end
