defmodule CodeMySpec.Analysis.StuckWork.Alert do
  @moduledoc "The last report sent for one stuck ledger item."
  use Ecto.Schema
  import Ecto.Changeset

  schema "stuck_work_alerts" do
    field :project_id, :binary_id
    field :kind, :string
    field :item_id, :string
    field :reported_at, :utc_datetime_usec
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [:project_id, :kind, :item_id, :reported_at])
    |> validate_required([:project_id, :kind, :item_id, :reported_at])
    |> validate_inclusion(:kind, ["run", "entry"])
    |> unique_constraint([:project_id, :kind, :item_id])
  end
end
