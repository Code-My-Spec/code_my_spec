defmodule CodeMySpec.Repo.Migrations.AddAttachmentsToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :attachments, :jsonb, default: "[]"
    end
  end
end
