defmodule CodeMySpec.Repo.Migrations.DropAccountIdFromPersonas do
  use Ecto.Migration

  @moduledoc """
  Follow-up to `ScopePersonasToProject`: that migration moved personas to
  project scope and removed `account_id` from the schema, but left the
  column (still NOT NULL) in the DB. New inserts via the changeset omit
  `account_id` and fail the NOT NULL constraint.

  This drops the column entirely — nothing in `lib/` reads it.
  """

  def up do
    alter table(:personas) do
      remove :account_id
    end
  end

  def down do
    alter table(:personas) do
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all)
    end

    create index(:personas, [:account_id])
  end
end
