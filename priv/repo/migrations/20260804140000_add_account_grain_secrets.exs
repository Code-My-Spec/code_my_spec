defmodule CodeMySpec.Repo.Migrations.AddAccountGrainSecrets do
  use Ecto.Migration

  @moduledoc """
  Lets a secret belong to an account rather than a project.

  A Hetzner API token names one Hetzner account, and the servers it can see
  outlive any project — that is the whole premise of story 994. Keying the
  credential on the project made what `/app/servers` showed depend on which
  project happened to be open.

  Two nullable owner columns are a discriminated union, so the check
  constraint makes it honest at the database: exactly one owner, never both
  and never neither. The account index is partial for the same reason the
  `environment` column is not nullable — under Postgres NULL semantics every
  NULL is distinct, so an unfiltered index would not constrain anything.
  """

  def up do
    alter table(:project_secrets) do
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all)
      modify :project_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create constraint(:project_secrets, :project_secrets_exactly_one_owner,
             check: "num_nonnulls(project_id, account_id) = 1"
           )

    create index(:project_secrets, [:account_id])

    create unique_index(:project_secrets, [:account_id, :key, :environment],
             where: "account_id IS NOT NULL",
             name: :project_secrets_account_id_key_environment_index
           )

    # The Hetzner API token moves up to the account that owns the project.
    # Done here rather than left to the caller so an existing install keeps
    # working: without it, `/app/servers` would go blank for every project the
    # moment resolution starts preferring the account.
    #
    # DISTINCT ON keeps one row per account when several projects on the same
    # account each carried a token — newest wins, which is the one most likely
    # to still be valid.
    execute("""
    INSERT INTO project_secrets (account_id, project_id, key, value, environment, inserted_at, updated_at)
    SELECT DISTINCT ON (p.account_id) p.account_id, NULL, s.key, s.value, s.environment, NOW(), NOW()
    FROM project_secrets s
    JOIN projects p ON p.id = s.project_id
    WHERE s.key = 'hetzner_api_token'
    ORDER BY p.account_id, s.updated_at DESC
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM project_secrets WHERE account_id IS NOT NULL")

    drop index(:project_secrets, [:account_id, :key, :environment],
           name: :project_secrets_account_id_key_environment_index
         )

    drop index(:project_secrets, [:account_id])
    drop constraint(:project_secrets, :project_secrets_exactly_one_owner)

    alter table(:project_secrets) do
      modify :project_id, :binary_id, null: false, from: {:binary_id, null: true}
      remove :account_id
    end
  end
end
