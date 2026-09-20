defmodule CodeMySpec.Repo.Migrations.APlanRecordsWhetherItSkippedTheConversation do
  use Ecto.Migration

  def change do
    alter table(:intake_plans) do
      add :procedural, :boolean
    end
  end
end
