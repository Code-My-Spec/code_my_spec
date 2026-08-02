defmodule CodeMySpec.Repo.Migrations.AddCmsRefreshSecretHashToProjects do
  use Ecto.Migration

  # Mirror of the server migration of the same name, which shipped without
  # one. The CLI loads `Projects.Project`, and that schema declares
  # `cms_refresh_secret_hash` — so without this column every select against
  # projects fails in the CLI, whether or not it touches the field.
  #
  # No unique index. The server needs one because it looks projects up by this
  # digest; the CLI never does, and an index on a column nothing queries is
  # cost without a reader.
  def change do
    alter table(:projects) do
      add :cms_refresh_secret_hash, :string
    end
  end
end
