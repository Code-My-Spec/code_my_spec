defmodule CodeMySpec.Analysis.FleetHold do
  @moduledoc """
  An operator hold on new analyzer runs and new task claims in a project.

  Stops new work only: a run already admitted, or a task already active or
  prepared, before the hold is placed is untouched and finishes on its own.
  See 783f3709 -- the hold existed only as a queued instruction offer, which
  an agent mid-run never sees until its next turn boundary; this is checked
  at the points new work is admitted instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "fleet_holds" do
    field(:project_id, :binary_id)
    field(:reason, :string)
    field(:placed_by, :string)
    field(:status, Ecto.Enum, values: [:active, :lifted], default: :active)
    field(:lifted_by, :string)
    field(:lifted_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(hold, attrs) do
    hold
    |> cast(attrs, [:project_id, :reason, :placed_by, :status, :lifted_by, :lifted_at])
    |> validate_required([:project_id, :reason, :status])
    |> unique_constraint(:project_id, name: :fleet_holds_one_active_per_project)
  end
end
