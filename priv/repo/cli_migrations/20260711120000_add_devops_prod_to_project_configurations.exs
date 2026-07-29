defmodule CodeMySpec.Repo.Migrations.AddDevopsProdToProjectConfigurations do
  use Ecto.Migration

  # Adds `devops` directly, even though the module name says devops_prod and
  # the Postgres copy of this migration adds `devops_prod`.
  #
  # The next migration (20260711150000) renames devops_prod -> devops. Against
  # SQLite that rename fails when BOTH migrations run in the same migrator
  # pass: the connection's schema is still stale from the ALTER TABLE ... ADD
  # above, so `RENAME COLUMN "devops_prod"` reports `no such column` even
  # though the column is there and the statement is correct. Run them in
  # separate passes and it works.
  #
  # That difference is exactly the difference between an upgrade and a fresh
  # install. Existing CLIs applied these two in different releases and were
  # fine; a brand-new install runs them together on first boot and `cms` could
  # not start at all. Surfaced by the devbox container, which is the first
  # thing to boot cms against an empty database.
  #
  # Adding the final column name here sidesteps the rename on fresh databases.
  # Editing an already-applied migration is safe in this direction: anyone who
  # has run 20260711120000 already has devops_prod and will take the rename
  # path in the next migration, which is guarded on that column existing.
  def change do
    alter table(:project_configurations) do
      # Default lives on the schema, never the migration.
      add :devops, :string
    end
  end
end
