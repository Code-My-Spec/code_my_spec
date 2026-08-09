defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToIssues do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_harness_id_to_issues`.

  Same purpose: record which working copy an issue was raised from, so "is this
  my checkout or another's?" is answerable from the record rather than from
  prose in the body. See the Postgres copy.

  No `references/2` here, for the reason the other CLI mirrors give: SQLite
  enforces foreign keys only with `PRAGMA foreign_keys` on, so the constraint
  would be decorative, and adding one to an existing table is a table rebuild.
  """

  def change do
    alter table(:issues) do
      add :harness_id, :binary_id
    end

    create index(:issues, [:project_id, :harness_id])
  end
end
