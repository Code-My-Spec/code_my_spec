defmodule CodeMySpec.Telemetry.HealthCheck do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "telemetry_health_checks" do
    field :project_id, :binary_id, primary_key: true
    field :environment, :string, primary_key: true
    field :reachable, :boolean
    field :reads, Ecto.Enum, values: [:ok, :error]
    field :writes, Ecto.Enum, values: [:ok, :refused, :error]
    field :checked_at, :utc_datetime_usec
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [:project_id, :environment, :reachable, :reads, :writes, :checked_at])
    |> validate_required([:project_id, :environment, :reachable, :reads, :writes, :checked_at])
    |> foreign_key_constraint(:project_id)
  end
end
