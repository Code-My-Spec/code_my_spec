defmodule CodeMySpec.Repo.Migrations.AnEnvironmentCanNameItsLegacyDatabase do
  use Ecto.Migration

  # Adopting an existing app means its data lives somewhere before `:server`
  # ever runs — another container on the same box, never a remote host (the
  # legacy app and `cms-postgres` always share a server). These two columns
  # are the only input the new `:import` step needs: when both are set, the
  # environment has a legacy database to copy; when either is blank, nothing
  # about setup or deploy changes. See knowledge/provisioning/steps, "Import".
  def change do
    alter table(:environments) do
      add :import_source_container, :string
      add :import_source_database, :string
    end
  end
end
