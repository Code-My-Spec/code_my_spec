defmodule CodeMySpec.Repo.Migrations.AModelChoiceBelongsToThePersonWhoMadeIt do
  @moduledoc """
  Story 984. `agent_model_settings` moves from the account to the user.

  The setting resolves against `integrations`, which is keyed by `user_id`. An
  account-level "QA runs on Z.ai" was therefore true for whoever pasted the key
  and a lie for everybody else on the account — and the settings screen had no
  way to say which.

  Existing rows are deleted rather than backfilled. There is no user on them to
  recover: an account has many members and nothing recorded which one chose.
  Guessing the owner would silently hand one member's choice to the account and
  call it theirs, which is the confusion this migration exists to end. The
  table is a day old and absent is a state the defaults already answer, so the
  cost of asking people to choose again is one visit to a page.
  """

  use Ecto.Migration

  def up do
    execute "DELETE FROM agent_model_settings"

    drop unique_index(:agent_model_settings, [:account_id, :role])

    alter table(:agent_model_settings) do
      remove :account_id
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create unique_index(:agent_model_settings, [:user_id, :role])
  end

  def down do
    execute "DELETE FROM agent_model_settings"

    drop unique_index(:agent_model_settings, [:user_id, :role])

    alter table(:agent_model_settings) do
      remove :user_id

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create unique_index(:agent_model_settings, [:account_id, :role])
  end
end
