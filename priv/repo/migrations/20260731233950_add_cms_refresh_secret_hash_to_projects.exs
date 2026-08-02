defmodule CodeMySpec.Repo.Migrations.AddCmsRefreshSecretHashToProjects do
  use Ecto.Migration

  # The digest a deployed app's refresh secret is looked up by. The secret
  # itself lives in the project's SOPS-encrypted environment and is never
  # stored here — a digest cannot be presented as a credential, and comparing
  # digests keeps the secret out of query logs.
  #
  # Same shape as `deploy_key_hash`, deliberately: one proven pattern for
  # "encrypted value, hashed lookup" rather than a second invented one.
  def change do
    alter table(:projects) do
      add :cms_refresh_secret_hash, :string
    end

    create unique_index(:projects, [:cms_refresh_secret_hash])
  end
end
