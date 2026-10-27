defmodule CodeMySpec.Repo.Migrations.RecordStoryPublicationRevisions do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :promoted_qa_commit, :string
      add :promoted_candidate_commit, :string
    end
  end
end
