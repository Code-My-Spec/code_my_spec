defmodule CodeMySpec.Repo.Migrations.ASpecFileNamesItsCriterion do
  @moduledoc """
  The SQLite counterpart of the Postgres `a_spec_file_names_its_criterion`.
  """
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :criterion_id, :bigint
    end

    create index(:files, [:criterion_id])
  end
end
