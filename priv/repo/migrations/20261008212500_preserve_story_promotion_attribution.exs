defmodule CodeMySpec.Repo.Migrations.PreserveStoryPromotionAttribution do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :promoted_working_copy_id, :uuid
      add :promoted_at, :utc_datetime_usec
    end
  end
end
