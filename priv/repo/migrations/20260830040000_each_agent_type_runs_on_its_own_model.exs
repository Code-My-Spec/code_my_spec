defmodule CodeMySpec.Repo.Migrations.EachAgentTypeRunsOnItsOwnModel do
  @moduledoc """
  Story 983. One row per account per agent type, saying what it launches on.

  No default on the column and no row created up front: absent is a real state
  that `Agents.Defaults` answers, and a row written at account creation would
  freeze whatever the defaults were that day.
  """

  use Ecto.Migration

  def change do
    create table(:agent_model_settings) do
      add :role, :string, null: false
      add :provider, :string, null: false
      add :model, :string

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    # One answer per type per account. Two rows for the same type is a launcher
    # picking whichever it read first, which is a coin toss nobody can see.
    create unique_index(:agent_model_settings, [:account_id, :role])
  end
end
