defmodule CodeMySpec.Repo.Migrations.AddClientUserIdToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :client_user_id, :integer
    end

    create index(:projects, [:client_user_id])
  end
end
