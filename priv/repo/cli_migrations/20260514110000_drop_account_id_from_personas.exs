defmodule CodeMySpec.Repo.Migrations.DropAccountIdFromPersonas do
  use Ecto.Migration

  @moduledoc """
  SQLite mirror of priv/repo/migrations/20260514110000_drop_account_id_from_personas.exs.
  See that file for context.
  """

  def up do
    drop_if_exists index(:personas, [:account_id])
    alter table(:personas) do
      remove :account_id
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Down migration for DropAccountIdFromPersonas is not supported — the column is gone."
  end
end
