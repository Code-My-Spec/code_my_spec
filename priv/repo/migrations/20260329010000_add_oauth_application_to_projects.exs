defmodule CodeMySpec.Repo.Migrations.AddOauthApplicationToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :oauth_application_id, references(:oauth_applications, on_delete: :nilify_all)
    end

    create index(:projects, [:oauth_application_id])
  end
end
