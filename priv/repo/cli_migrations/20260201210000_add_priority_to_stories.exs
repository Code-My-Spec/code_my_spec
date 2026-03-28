defmodule CodeMySpecCli.Repo.Migrations.AddPriorityToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :priority, :integer
    end
  end
end
