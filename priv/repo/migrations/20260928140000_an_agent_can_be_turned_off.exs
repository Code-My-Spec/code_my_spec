defmodule CodeMySpec.Repo.Migrations.AnAgentCanBeTurnedOff do
  use Ecto.Migration

  # 39af5611: two intents, kept apart from what the process did. `off_at` set
  # means off (keeps its seat); `retired_at` set means retired (seat freed,
  # never runs again). Nullable, no defaults.
  def change do
    alter table(:agents) do
      add :off_at, :utc_datetime_usec
      add :off_by, :text
      add :off_reason, :text
      add :retired_at, :utc_datetime_usec
      add :retired_by, :text
      add :retired_reason, :text
    end
  end
end
