defmodule CodeMySpec.Repo.Migrations.AddMailboxEngineGeneration do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :mailbox_generation, :text
    end
  end
end
