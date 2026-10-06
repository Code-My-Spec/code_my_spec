defmodule CodeMySpec.Repo.Migrations.ATurnRecordsTheTokensItUsed do
  use Ecto.Migration

  # One row per finished turn, not a running total: a provider that reports no
  # usage at all (criterion 1978) must read back as unknown rather than zero,
  # and a column with a default of 0 cannot tell those apart. `story_id` is
  # read off the agent at the moment the turn lands, not kept in sync with it
  # afterward -- a turn belongs to whatever story was active when it happened.
  def change do
    create table(:agent_turns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :project_id, :binary_id, null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, on_delete: :nilify_all)
      add :provider, :string
      add :model, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cache_read_tokens, :integer
      add :cache_write_tokens, :integer

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:agent_turns, [:agent_id])
    create index(:agent_turns, [:story_id])
    create index(:agent_turns, [:project_id])
  end
end
