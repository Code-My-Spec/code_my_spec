defmodule CodeMySpec.Repo.SqliteMigrations.RemotePromotionsKeepTheirDeviceSync do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :development_branch, :string, default: "main", null: false
      add :promotion_sync, :map, default: %{}, null: false
    end

    alter table(:working_copies) do
      add :promotion_sync, :map, default: %{}, null: false
    end
  end
end
