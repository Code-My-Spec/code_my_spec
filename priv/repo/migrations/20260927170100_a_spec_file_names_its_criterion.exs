defmodule CodeMySpec.Repo.Migrations.ASpecFileNamesItsCriterion do
  @moduledoc """
  The criterion a spex file covers, bound from the number its `spex` call
  names rather than parsed out of its filename.

  A plain integer, not a foreign key: criteria are never deleted, and a file
  row is rewritten by every manifest anyway.
  """
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :criterion_id, :bigint
    end

    create index(:files, [:criterion_id])
  end
end
