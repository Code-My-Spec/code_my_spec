defmodule CodeMySpec.Repo.Migrations.ADevBoxSaysWhetherItIsUp do
  use Ecto.Migration

  # Story 1138: the last moment a device's harness was known to be connected,
  # recorded when its last connected working copy's channel actually closes --
  # distinct from `last_seen_at`, which `mark_alive/1` touches on activity
  # (manifests, announces) rather than on the up/down transition itself.
  def change do
    alter table(:devices) do
      add(:last_up_at, :utc_datetime_usec)
    end
  end
end
