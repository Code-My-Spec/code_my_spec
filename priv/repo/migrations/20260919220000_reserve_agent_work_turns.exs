defmodule CodeMySpec.Repo.Migrations.ReserveAgentWorkTurns do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :work_request_id, :string
      add :work_requested_at, :utc_datetime_usec
    end
  end
end
