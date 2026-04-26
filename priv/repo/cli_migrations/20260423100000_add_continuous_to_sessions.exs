defmodule CodeMySpec.Repo.Migrations.AddContinuousToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :continuous, :boolean
    end
  end
end
