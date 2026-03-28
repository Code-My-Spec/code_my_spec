defmodule CodeMySpec.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :description, :string
      add :module_name, :string
      add :code_repo, :string
      add :docs_repo, :string
      add :client_api_url, :string
      add :deploy_key, :string
      add :google_analytics_property_id, :string
      add :status, :string
      add :setup_error, :string
      add :account_id, :integer
      add :user_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:user_id])
    create index(:projects, [:account_id])
  end
end
