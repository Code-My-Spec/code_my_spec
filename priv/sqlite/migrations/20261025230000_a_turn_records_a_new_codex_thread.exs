defmodule CodeMySpec.Repo.Migrations.ATurnRecordsANewCodexThread do
  use Ecto.Migration

  # Why a turn started a new Codex thread partway through its conversation,
  # sending the whole transcript uncached; nil when it did not.
  def change do
    alter table(:agent_turns) do
      add :fresh_thread, :string
    end
  end
end
