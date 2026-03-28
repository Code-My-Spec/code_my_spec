defmodule CodeMySpec.Repo.Migrations.RemoveStoryDirtyTracking do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      remove :code_changed_at, :utc_datetime
      remove :spex_analyzed_at, :utc_datetime
    end
  end
end
