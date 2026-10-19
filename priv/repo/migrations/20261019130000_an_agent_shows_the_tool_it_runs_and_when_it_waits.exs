defmodule CodeMySpec.Repo.Migrations.AnAgentShowsTheToolItRunsAndWhenItWaits do
  use Ecto.Migration

  # Story 1127: an external agent's status comes from its own hooks, and the
  # team panel shows an Alloy agent and a terminal session alike.
  def change do
    alter table(:agents) do
      add :current_tool, :string
      add :waiting_since, :utc_datetime_usec
    end
  end
end
