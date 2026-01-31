defmodule CodeMySpec.Repo.Migrations.AddEnvironmentToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :environment, :map
    end
  end
end
