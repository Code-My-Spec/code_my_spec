defmodule CodeMySpec.Repo.Migrations.APromotionCanAskForFreshRuns do
  use Ecto.Migration

  # `promote(fresh: true)`: the gate ignores runs recorded at the commit before
  # the promote and starts its own (issue c9d61407).
  def change do
    alter table(:promotion_queue_entries) do
      add :fresh, :boolean
    end
  end
end
