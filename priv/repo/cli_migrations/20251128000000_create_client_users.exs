defmodule CodeMySpec.Repo.Migrations.CreateClientUsers do
  use Ecto.Migration

  def change do
    create table(:client_users) do
      add :email, :string
      add :oauth_token, :binary
      add :oauth_refresh_token, :binary
      add :oauth_expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:client_users, [:email])
  end
end
