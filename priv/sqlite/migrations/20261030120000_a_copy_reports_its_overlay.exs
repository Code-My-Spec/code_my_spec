defmodule CodeMySpec.Repo.SqliteMigrations.ACopyReportsItsOverlay do
  use Ecto.Migration

  def change do
    create table(:copy_overlays, primary_key: false) do
      add :working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :read_model, :string, null: false
      add :head, :string
      add :behind, :integer
      add :dirty, :boolean
      add :verdicts, :binary, null: false
      add :reported_at, :utc_datetime_usec, null: false
      add :mismatches, :integer
      add :clean_reports, :integer, null: false
      add :compared_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:copy_overlays, [:project_id])
  end
end
