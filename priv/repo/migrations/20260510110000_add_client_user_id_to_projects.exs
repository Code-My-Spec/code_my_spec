defmodule CodeMySpec.Repo.Migrations.AddClientUserIdToProjects do
  use Ecto.Migration

  @moduledoc """
  CLI-side concern surfaced in the shared Project schema. The server
  never reads or writes this column — it exists so the schema stays
  query-safe against both the server's Postgres `projects` table and
  the CLI's SQLite `projects` table (which uses `client_user_id` to
  scope the local-install ladder gate to the active OAuth user).
  """

  def change do
    alter table(:projects) do
      add :client_user_id, :integer
    end
  end
end
