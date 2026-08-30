defmodule CodeMySpec.Repo.Migrations.AnAgentRecordsTheModelItStartedOn do
  @moduledoc """
  Story 983. Pointing an agent type at a different model must not move one that
  is already running, so the model has to be on the row rather than read back
  from a setting that has since changed.

  Nullable, and no default: agents started before this predate the idea, and a
  backfilled guess would be a claim about what they ran on that nobody checked.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :model, :string
    end
  end
end
