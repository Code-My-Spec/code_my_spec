defmodule CodeMySpec.Repo.Migrations.AddDirtyTrackingToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :files_changed_at, :utc_datetime
      add :last_analyzed_at, :map, default: %{}
    end

    create index(:components, [:files_changed_at])
  end
end
