defmodule CodeMySpec.Repo.Migrations.ACloudBoxHasARoutineToFire do
  use Ecto.Migration

  # Story 1136: a Claude Code cloud box can be started by firing its routine.
  # The routine id (`trig_…`) and its per-routine fire token live on the box;
  # the token is stored encrypted.
  def change do
    alter table(:devices) do
      add(:fire_routine_id, :string)
      add(:fire_token, :binary)
    end
  end
end
