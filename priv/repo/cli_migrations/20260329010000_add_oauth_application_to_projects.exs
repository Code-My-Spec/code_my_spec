defmodule CodeMySpec.Repo.Migrations.AddOauthApplicationToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :oauth_application_id, :integer
    end

    create index(:projects, [:oauth_application_id])
  end
end
