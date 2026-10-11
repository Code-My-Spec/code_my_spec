defmodule CodeMySpec.Repo.Migrations.AddQaReadyCommitToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add(:qa_ready_commit, :string)
      add(:qa_ready_at, :utc_datetime_usec)
    end
  end
end
