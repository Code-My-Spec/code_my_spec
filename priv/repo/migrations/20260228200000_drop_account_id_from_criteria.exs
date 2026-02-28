defmodule CodeMySpec.Repo.Migrations.DropAccountIdFromCriteria do
  use Ecto.Migration

  def change do
    drop_if_exists index(:criteria, [:account_id])

    alter table(:criteria) do
      remove :account_id, references(:accounts, type: :id), null: false
    end
  end
end
