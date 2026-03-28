defmodule CodeMySpec.Repo.Migrations.DropAccountIdFromCriteria do
  use Ecto.Migration

  def up do
    execute "DROP INDEX IF EXISTS criteria_account_id_index"
    execute "ALTER TABLE criteria DROP COLUMN account_id"
  end

  def down do
    alter table(:criteria) do
      add :account_id, :binary_id
    end

    create index(:criteria, [:account_id])
  end
end
