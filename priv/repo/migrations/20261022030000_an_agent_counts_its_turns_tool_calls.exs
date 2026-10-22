defmodule CodeMySpec.Repo.Migrations.AnAgentCountsItsTurnsToolCalls do
  use Ecto.Migration

  # The team panel's tally: tool calls in the agent's current turn.
  def change do
    alter table(:agents) do
      add :turn_tool_count, :integer
    end
  end
end
