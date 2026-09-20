defmodule CodeMySpec.Repo.Migrations.APlanRecordsWhetherTheVisitorIsTechnical do
  use Ecto.Migration

  def change do
    alter table(:intake_plans) do
      add :technical, :boolean
    end
  end
end
