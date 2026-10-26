defmodule CodeMySpec.Repo.SqliteMigrations.AddQaEvidenceCorrections do
  use Ecto.Migration

  def change do
    alter table(:qa_attempts) do
      add(:evidence_corrections, {:array, :map}, default: [], null: false)
    end
  end
end
