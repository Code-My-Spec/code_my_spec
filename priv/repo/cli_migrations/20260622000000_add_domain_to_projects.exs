defmodule CodeMySpec.Repo.Migrations.AddDomainToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :domain, :string
      add :domain_verified_at, :utc_datetime
    end
  end
end
