defmodule CodeMySpec.Repo.Migrations.AddSyncedAtToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :synced_at, :utc_datetime
    end
  end
end
