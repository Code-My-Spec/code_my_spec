defmodule CodeMySpec.Repo.Migrations.ChangeAccountsToUuid do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Drop indexes that reference account_id
    drop_if_exists unique_index(:members, [:user_id, :account_id])

    drop_if_exists unique_index(:invitations, [:email, :account_id],
                     where: "accepted_at IS NULL AND cancelled_at IS NULL",
                     name: :unique_account_email_when_nulls
                   )

    drop_if_exists index(:members, [:account_id])
    drop_if_exists index(:invitations, [:account_id])
    drop_if_exists index(:sessions, [:account_id])
    drop_if_exists index(:criteria, [:account_id])
    drop_if_exists index(:rules, [:account_id])
    drop_if_exists index(:components, [:account_id])
    drop_if_exists index(:stories, [:account_id])
    drop_if_exists index(:content_admin, [:account_id])
    drop_if_exists index(:projects, [:account_id])

    # Drop foreign key constraints from tables that reference accounts
    drop_if_exists constraint(:members, "members_account_id_fkey")
    drop_if_exists constraint(:invitations, "invitations_account_id_fkey")
    drop_if_exists constraint(:sessions, "sessions_account_id_fkey")
    drop_if_exists constraint(:criteria, "criteria_account_id_fkey")
    drop_if_exists constraint(:rules, "rules_account_id_fkey")
    drop_if_exists constraint(:components, "components_account_id_fkey")
    drop_if_exists constraint(:stories, "stories_account_id_fkey")
    drop_if_exists constraint(:content_admin, "content_admin_account_id_fkey")
    drop_if_exists constraint(:projects, "projects_account_id_fkey")

    # Add new UUID columns to all tables
    alter table(:accounts) do
      add :new_id, :uuid
    end

    alter table(:members) do
      add :new_account_id, :uuid
    end

    alter table(:invitations) do
      add :new_account_id, :uuid
    end

    alter table(:sessions) do
      add :new_account_id, :uuid
    end

    alter table(:criteria) do
      add :new_account_id, :uuid
    end

    alter table(:rules) do
      add :new_account_id, :uuid
    end

    alter table(:components) do
      add :new_account_id, :uuid
    end

    alter table(:stories) do
      add :new_account_id, :uuid
    end

    alter table(:content_admin) do
      add :new_account_id, :uuid
    end

    alter table(:projects) do
      add :new_account_id, :uuid
    end

    alter table(:user_preferences) do
      add :new_active_account_id, :uuid
    end

    # Generate UUIDs for existing accounts using Elixir code
    flush()

    repo = CodeMySpec.Repo

    # For each account, generate a UUID and store the mapping
    id_mapping =
      repo.all(
        from(a in "accounts",
          select: %{old_id: a.id}
        )
      )
      |> Enum.map(fn %{old_id: old_id} ->
        {old_id, Ecto.UUID.generate()}
      end)
      |> Map.new()

    # Update accounts with new UUIDs
    Enum.each(id_mapping, fn {old_id, new_uuid} ->
      {:ok, binary_uuid} = Ecto.UUID.dump(new_uuid)

      repo.query!(
        "UPDATE accounts SET new_id = $1 WHERE id = $2",
        [binary_uuid, old_id]
      )
    end)

    # Update all referencing tables
    Enum.each(id_mapping, fn {old_id, new_uuid} ->
      {:ok, binary_uuid} = Ecto.UUID.dump(new_uuid)

      repo.query!(
        "UPDATE members SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE invitations SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE sessions SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE criteria SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE rules SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE components SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE stories SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE content_admin SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE projects SET new_account_id = $1 WHERE account_id = $2",
        [binary_uuid, old_id]
      )

      repo.query!(
        "UPDATE user_preferences SET new_active_account_id = $1 WHERE active_account_id = $2",
        [binary_uuid, old_id]
      )
    end)

    flush()

    # Drop old columns
    alter table(:accounts) do
      remove :id
    end

    alter table(:members) do
      remove :account_id
    end

    alter table(:invitations) do
      remove :account_id
    end

    alter table(:sessions) do
      remove :account_id
    end

    alter table(:criteria) do
      remove :account_id
    end

    alter table(:rules) do
      remove :account_id
    end

    alter table(:components) do
      remove :account_id
    end

    alter table(:stories) do
      remove :account_id
    end

    alter table(:content_admin) do
      remove :account_id
    end

    alter table(:projects) do
      remove :account_id
    end

    alter table(:user_preferences) do
      remove :active_account_id
    end

    # Rename new columns to original names
    rename table(:accounts), :new_id, to: :id
    rename table(:members), :new_account_id, to: :account_id
    rename table(:invitations), :new_account_id, to: :account_id
    rename table(:sessions), :new_account_id, to: :account_id
    rename table(:criteria), :new_account_id, to: :account_id
    rename table(:rules), :new_account_id, to: :account_id
    rename table(:components), :new_account_id, to: :account_id
    rename table(:stories), :new_account_id, to: :account_id
    rename table(:content_admin), :new_account_id, to: :account_id
    rename table(:projects), :new_account_id, to: :account_id
    rename table(:user_preferences), :new_active_account_id, to: :active_account_id

    # Set accounts.id as primary key
    execute "ALTER TABLE accounts ADD PRIMARY KEY (id)"

    # Make columns NOT NULL where they should be
    execute "ALTER TABLE members ALTER COLUMN account_id SET NOT NULL"
    execute "ALTER TABLE invitations ALTER COLUMN account_id SET NOT NULL"
    execute "ALTER TABLE components ALTER COLUMN account_id SET NOT NULL"
    execute "ALTER TABLE content_admin ALTER COLUMN account_id SET NOT NULL"
    execute "ALTER TABLE criteria ALTER COLUMN account_id SET NOT NULL"

    # Recreate foreign key constraints
    alter table(:members) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:invitations) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:sessions) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :nothing)
    end

    alter table(:criteria) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:rules) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :nothing)
    end

    alter table(:components) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:stories) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:content_admin) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :delete_all)
    end

    alter table(:projects) do
      modify :account_id, references(:accounts, type: :uuid, on_delete: :nothing)
    end

    # Recreate indexes
    create index(:members, [:account_id])
    create index(:invitations, [:account_id])
    create index(:sessions, [:account_id])
    create index(:criteria, [:account_id])
    create index(:rules, [:account_id])
    create index(:components, [:account_id])
    create index(:stories, [:account_id])
    create index(:content_admin, [:account_id])
    create index(:projects, [:account_id])

    # Recreate unique indexes
    create unique_index(:members, [:user_id, :account_id])

    create unique_index(:invitations, [:email, :account_id],
             where: "accepted_at IS NULL AND cancelled_at IS NULL",
             name: :unique_account_email_when_nulls
           )
  end

  def down do
    raise "This migration cannot be safely reversed. UUID to integer conversion would lose data."
  end
end
