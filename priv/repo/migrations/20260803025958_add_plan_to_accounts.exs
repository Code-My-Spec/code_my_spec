defmodule CodeMySpec.Repo.Migrations.AddPlanToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :plan, :string
    end

    # No default on the column — defaults belong on the schema, where they are
    # visible to anyone reading the struct. Existing accounts are backfilled
    # explicitly so the column is never silently null for a row that predates
    # it.
    execute "UPDATE accounts SET plan = 'free' WHERE plan IS NULL",
            "SELECT 1"
  end
end
